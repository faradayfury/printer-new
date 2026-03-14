/*

GENERAL
This program converts CUPS raster data to Zenographics XQX/ZjStream format
for driving HP LaserJet P1005/P1006/P1007/P1008 printers on macOS.

It replaces the Ghostscript-based pipeline (gs | foo2xqx), eliminating
the Ghostscript dependency entirely. CUPS's built-in cgpdftoraster
filter handles PDF-to-raster conversion, and this filter handles
raster-to-XQX conversion.

Pipeline:  PDF -> cgpdftoraster -> rastertoxqx -> printer

DERIVATION
XQX protocol output and JBIG compression code derived from foo2xqx.c
by Rick Richardson. JBIG-KIT library by Markus Kuhn.

LICENSE
This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or (at
your option) any later version.

*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include <time.h>
#include <cups/cups.h>
#include <cups/raster.h>
#include "jbig.h"
#include "xqx.h"

/*
 * Globals
 */
static int	Debug = 0;
static int	ResX = 600;
static int	ResY = 600;
static int	Bpp = 1;
static int	PaperCode = DMPAPER_LETTER;
static int	Copies = 1;
static int	SourceCode = DMBIN_AUTO;
static int	MediaCode = DMMEDIA_PLAIN;
static int	EconoMode = 0;
static int	PrintDensity = 3;
static int	PageNum = 0;
static int	RealWidth;
static int	OutputStartPlane = 1;
static int	SaveToner = 0;

static long JbgOptions[5] =
{
    JBG_ILEAVE | JBG_SMID,
    JBG_DELAY_AT | JBG_LRLTWO | JBG_TPDON | JBG_TPBON | JBG_DPON,
    128,
    16,
    0
};

/*
 * Utility functions
 */
static void
debug(int level, char *fmt, ...)
{
    va_list ap;

    if (Debug < level)
	return;

    setvbuf(stderr, (char *) NULL, _IOLBF, BUFSIZ);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static void
error(int fatal, char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);

    if (fatal)
	exit(fatal);
}

/*
 * XQX protocol output (from foo2xqx.c)
 */
static void
chunk_write(unsigned long type, unsigned long items, FILE *fp)
{
    XQX_HEADER	chunk;
    int		rc;

    chunk.type = be32(type);
    chunk.items = be32(items);
    rc = fwrite(&chunk, 1, sizeof(XQX_HEADER), fp);
    if (rc == 0) error(1, "fwrite(chunk): rc == 0!\n");
}

static void
item_uint32_write(unsigned long item, unsigned long value, FILE *fp)
{
    XQX_ITEM_UINT32 item_uint32;
    int		rc;

    item_uint32.header.type = be32(item);
    item_uint32.header.size = be32(sizeof(DWORD));
    item_uint32.value = be32(value);
    rc = fwrite(&item_uint32, 1, sizeof(XQX_ITEM_UINT32), fp);
    if (rc == 0) error(1, "fwrite(item): rc == 0!\n");
}

static void
item_bytelut_write(unsigned long item, unsigned long len, BYTE *buf, FILE *fp)
{
    XQX_ITEM_HEADER header;
    int		rc;

    header.type = be32(item);
    header.size = be32(len);
    rc = fwrite(&header, 1, sizeof(XQX_ITEM_HEADER), fp);
    if (rc == 0) error(1, "fwrite(hdr): rc == 0!\n");
    rc = fwrite(buf, 1, len, fp);
    if (rc == 0) error(1, "fwrite(data): rc == 0!\n");
}

/*
 * Linked list of JBIG compressed data
 */
typedef struct _BIE_CHAIN{
    unsigned char	*data;
    size_t		len;
    struct _BIE_CHAIN	*next;
} BIE_CHAIN;

static void
free_chain(BIE_CHAIN *chain)
{
    BIE_CHAIN	*next;
    next = chain;
    while ((chain = next))
    {
	next = chain->next;
	if (chain->data)
	    free(chain->data);
	free(chain);
    }
}

static int
write_plane(int planeNum, BIE_CHAIN **root, FILE *fp)
{
    BIE_CHAIN	*current = *root;
    int		len;
    int		first;
    BYTE	*bih;
    int		rc;

    if (!current)
	error(1, "There is no JBIG!\n");
    if (!current->next)
	error(1, "There is no or wrong JBIG header!\n");
    if (current->len != 20)
	error(1, "wrong BIH length\n");

    bih = current->data;
    first = 1;
    for (current = *root; current && current->len; current = current->next)
    {
	if (current == *root)
	    continue;

	len = current->len;

	chunk_write(XQX_START_PLANE, 4, fp);
	item_uint32_write(0x80000000, first ? 64 : 48, fp);
	item_uint32_write(0x40000000, 0, fp);
	if (first)
	    item_bytelut_write(XQXI_BIH, 20, bih, fp);
	else
	    item_uint32_write(0x40000003, 1, fp);
	item_uint32_write(XQXI_END, 0xdeadbeef, fp);

	chunk_write(XQX_JBIG, len, fp);
	if (len)
	{
	    rc = fwrite(current->data, 1, len, fp);
	    if (rc == 0) error(1, "fwrite(jbig): rc == 0!\n");
	}

	chunk_write(XQX_END_PLANE, 0, fp);
	first = 0;
    }

    free_chain(*root);
    return 0;
}

static void
start_page(BIE_CHAIN **root, FILE *ofp)
{
    BIE_CHAIN		*current = *root;
    unsigned long	w, h;
    int			nitems;
    static int		pageno = 0;

    if (!current)
	error(1, "There is no JBIG!\n");
    if (!current->next)
	error(1, "There is no or wrong JBIG header!\n");
    if (current->len != 20)
	error(1, "wrong BIH length\n");

    w = (((long) current->data[ 4] << 24)
	    | ((long) current->data[ 5] << 16)
	    | ((long) current->data[ 6] <<  8)
	    | (long) current->data[ 7]);
    h = (((long) current->data[ 8] << 24)
	    | ((long) current->data[ 9] << 16)
	    | ((long) current->data[10] <<  8)
	    | (long) current->data[11]);

    nitems = 15;

    chunk_write(XQX_START_PAGE, nitems, ofp);
    item_uint32_write(0x80000000, 180, ofp);
    item_uint32_write(0x20000005,              1,              ofp);
    item_uint32_write(XQXI_DMDEFAULTSOURCE,     SourceCode,     ofp);
    item_uint32_write(XQXI_DMMEDIATYPE,         MediaCode,      ofp);
    item_uint32_write(0x20000007,              1,              ofp);

    item_uint32_write(XQXI_RESOLUTION_X,        ResX,           ofp);
    item_uint32_write(XQXI_RESOLUTION_Y,        ResY,           ofp);
    item_uint32_write(XQXI_RASTER_X,            w,              ofp);
    item_uint32_write(XQXI_RASTER_Y,            h,              ofp);
    item_uint32_write(XQXI_VIDEO_BPP,           Bpp,            ofp);

    item_uint32_write(XQXI_VIDEO_X,             RealWidth / Bpp,ofp);
    item_uint32_write(XQXI_VIDEO_Y,             h,              ofp);
    item_uint32_write(XQXI_ECONOMODE,           EconoMode,      ofp);
    item_uint32_write(XQXI_DMPAPER,             PaperCode,      ofp);
    item_uint32_write(XQXI_END,                 0xdeadbeef,     ofp);

    ++pageno;
    fprintf(stderr, "PAGE: %d %d\n", pageno, Copies);
}

static void
end_page(FILE *ofp)
{
    chunk_write(XQX_END_PAGE, 0, ofp);
}

static void
write_page(BIE_CHAIN **root, FILE *ofp)
{
    start_page(root, ofp);

    if (OutputStartPlane)
	write_plane(4, root, ofp);
    else
	write_plane(0, root, ofp);

    end_page(ofp);
}

/*
 * JBIG compression callback — builds linked list of compressed data.
 * First item is the BIH (20 bytes), subsequent items are 65536 bytes.
 */
static void
output_jbig(unsigned char *start, size_t len, void *cbarg)
{
    BIE_CHAIN	*current, **root = (BIE_CHAIN **) cbarg;
    int		size = 65536;

    if ( (*root) == NULL)
    {
	(*root) = malloc(sizeof(BIE_CHAIN));
	if (!(*root))
	    error(1, "Can't allocate space for chain\n");

	(*root)->data = NULL;
	(*root)->next = NULL;
	(*root)->len = 0;
	size = 20;
	if (len != 20)
	    error(1, "First chunk must be BIH and 20 bytes long\n");
    }

    current = *root;
    while (current->next)
	current = current->next;

    while (len > 0)
    {
	int	amt, left;

	if (!current->data)
	{
	    current->data = malloc(size);
	    if (!current->data)
		error(1, "Can't allocate space for compressed data\n");
	}

	left = size - current->len;
	amt = (len > left) ? left : len;
	memcpy(current->data + current->len, start, amt);
	current->len += amt;
	len -= amt;
	start += amt;

	if (current->len == size)
	{
	    current->next = malloc(sizeof(BIE_CHAIN));
	    if (!current->next)
		error(1, "Can't allocate space for chain\n");
	    current = current->next;
	    current->data = NULL;
	    current->next = NULL;
	    current->len = 0;
	}
    }
}

/*
 * JBIG-compress a 1-bpp page bitmap and write as XQX
 */
static int
pbm_page(unsigned char *buf, int w, int h, FILE *ofp)
{
    BIE_CHAIN		*chain = NULL;
    unsigned char	*bitmaps[1];
    struct jbg_enc_state se;

    RealWidth = w;
    w = (w + 127) & ~127;

    if (SaveToner)
    {
	int	x, y;
	int	bpl, bpl16;

	bpl = (w + 7) / 8;
	bpl16 = (bpl + 15) & ~15;

	for (y = 0; y < h; y += 2)
	    for (x = 0; x < bpl16; ++x)
		buf[y*bpl16 + x] &= 0x55;
	for (y = 1; y < h; y += 2)
	    for (x = 0; x < bpl16; ++x)
		buf[y*bpl16 + x] &= 0xaa;
    }

    *bitmaps = buf;

    jbg_enc_init(&se, w, h, 1, bitmaps, output_jbig, &chain);
    jbg_enc_options(&se, JbgOptions[0], JbgOptions[1],
		    JbgOptions[2], JbgOptions[3], JbgOptions[4]);
    jbg_enc_out(&se);
    jbg_enc_free(&se);

    write_page(&chain, ofp);

    return 0;
}

static void
start_doc(FILE *fp)
{
    char	header[4] = ",XQX";	// Big-endian data
    int		nitems;
    time_t	now;
    struct tm	*tmp;
    char	datetime[14+1];

    now = time(NULL);
    tmp = localtime(&now);
    strftime(datetime, sizeof(datetime), "%Y%m%d%H%M%S", tmp);

    fprintf(fp, "\033%%-12345X@PJL JOB\n");
    fprintf(fp, "@PJL SET JAMRECOVERY=OFF\n");
    fprintf(fp, "@PJL SET DENSITY=%d\n", PrintDensity);
    fprintf(fp, "@PJL SET ECONOMODE=%s\n", EconoMode ? "ON" : "OFF");
    fprintf(fp, "@PJL SET RET=MEDIUM\n");
    fprintf(fp, "@PJL INFO STATUS\n");
    fprintf(fp, "@PJL USTATUS DEVICE = ON\n");
    fprintf(fp, "@PJL USTATUS JOB = ON\n");
    fprintf(fp, "@PJL USTATUS PAGE = ON\n");
    fprintf(fp, "@PJL USTATUS TIMED = 30\n");
    fprintf(fp, "@PJL SET JOBATTR=\"JobAttr4=%s\"", datetime);
    fputc(0, fp);
    fprintf(fp, "\033%%-12345X");
    fwrite(header, 1, sizeof(header), fp);

    nitems = 7;

    chunk_write(XQX_START_DOC, nitems, fp);

    item_uint32_write(0x80000000,	84,			fp);
    item_uint32_write(0x10000005,	1,			fp);
    item_uint32_write(0x10000001,	0,			fp);
    item_uint32_write(XQXI_DMDUPLEX,	0,			fp);
    item_uint32_write(0x10000000,	0,			fp);
    item_uint32_write(0x10000003,	1,			fp);
    item_uint32_write(XQXI_END,		0xdeadbeef,		fp);
}

static void
end_doc(FILE *fp)
{
    chunk_write(XQX_END_DOC, 0, fp);

    fprintf(fp, "\033%%-12345X@PJL EOJ\n");
    fprintf(fp, "\033%%-12345X");
}

/*
 * Map PPD page size name to XQX paper code
 */
static int
paper_code_from_name(const char *name)
{
    if (!name || !name[0])		return DMPAPER_LETTER;
    if (!strcmp(name, "Letter"))		return DMPAPER_LETTER;
    if (!strcmp(name, "Legal"))		return DMPAPER_LEGAL;
    if (!strcmp(name, "Executive"))	return DMPAPER_EXECUTIVE;
    if (!strcmp(name, "A4"))		return DMPAPER_A4;
    if (!strcmp(name, "A5"))		return DMPAPER_A5;
    if (!strcmp(name, "B5"))		return DMPAPER_B5;
    if (!strcmp(name, "Env10"))		return DMPAPER_ENV_10;
    if (!strcmp(name, "EnvDL"))		return DMPAPER_ENV_DL;
    if (!strcmp(name, "EnvC5"))		return DMPAPER_ENV_C5;
    if (!strcmp(name, "EnvMonarch"))	return DMPAPER_ENV_MONARCH;
    return DMPAPER_LETTER;
}

/*
 * Map PPD media type name to XQX media code
 */
static int
media_code_from_name(const char *name)
{
    if (!name || !name[0])		return DMMEDIA_PLAIN;
    if (!strcmp(name, "Plain"))		return DMMEDIA_PLAIN;
    if (!strcmp(name, "Transparency"))	return DMMEDIA_TRANSPARENCY;
    if (!strcmp(name, "Envelope"))	return DMMEDIA_ENVELOPE;
    if (!strcmp(name, "Labels"))		return DMMEDIA_LABELS;
    if (!strcmp(name, "Heavy"))		return DMMEDIA_HEAVY;
    if (!strcmp(name, "Letterhead"))	return DMMEDIA_LETTERHEAD;
    return DMMEDIA_PLAIN;
}

/*
 * Map PPD MediaPosition to XQX source code
 */
static int
source_code_from_position(unsigned position)
{
    switch (position)
    {
    case 0:  return DMBIN_AUTO;
    case 1:  return DMBIN_TRAY1;
    case 4:  return DMBIN_MANUAL;
    default: return DMBIN_AUTO;
    }
}

/*
 * Convert an 8bpp grayscale scanline to 1bpp packed bitmap.
 *
 * CUPS_CSPACE_W (luminance): 0=black, 255=white
 * CUPS_CSPACE_K (black ink):  0=white, 255=black
 * PBM convention:             0=white, 1=black
 */
static void
threshold_line(const unsigned char *src, unsigned char *dst,
	       unsigned width, cups_cspace_t cs)
{
    unsigned	x;
    unsigned char byte = 0;

    for (x = 0; x < width; x++)
    {
	int is_black;

	if (cs == CUPS_CSPACE_W || cs == CUPS_CSPACE_SW)
	    is_black = (src[x] < 128);
	else
	    is_black = (src[x] >= 128);

	if (is_black)
	    byte |= (0x80 >> (x & 7));

	if ((x & 7) == 7)
	{
	    dst[x >> 3] = byte;
	    byte = 0;
	}
    }
    if (width & 7)
	dst[width >> 3] = byte;
}

/*
 * Main — CUPS raster filter
 *
 * Usage: rastertoxqx job-id user title copies options [filename]
 *
 * Reads CUPS raster from stdin (piped from cgpdftoraster),
 * writes XQX stream to stdout (sent to USB backend).
 */
int
main(int argc, char *argv[])
{
    cups_raster_t	*ras;
    cups_page_header2_t	header;
    unsigned		y;

    if (argc < 6 || argc > 7)
    {
	fprintf(stderr,
	    "Usage: %s job-id user title copies options [file]\n",
	    argv[0]);
	return 1;
    }

    Copies = atoi(argv[4]);
    if (Copies < 1)
	Copies = 1;

    ras = cupsRasterOpen(0, CUPS_RASTER_READ);
    if (!ras)
    {
	fprintf(stderr, "ERROR: rastertoxqx: Cannot open raster stream\n");
	return 1;
    }

    start_doc(stdout);

    while (cupsRasterReadHeader2(ras, &header))
    {
	unsigned	w = header.cupsWidth;
	unsigned	h = header.cupsHeight;
	unsigned	bpl, bpl16;
	unsigned char	*buf;
	int		copies, copy;

	if (w == 0 || h == 0)
	{
	    debug(1, "Skipping blank page (%ux%u)\n", w, h);
	    continue;
	}

	/* Extract printer settings from raster page header */
	ResX = header.HWResolution[0];
	ResY = header.HWResolution[1];
	Bpp = ResX / 600;
	if (Bpp < 1) Bpp = 1;
	ResX = 600;

	PaperCode  = paper_code_from_name(header.cupsPageSizeName);
	MediaCode  = media_code_from_name(header.MediaType);
	SourceCode = source_code_from_position(header.MediaPosition);

	debug(1, "Page: %ux%u px, %ux%u dpi, bpp=%d cs=%d, "
	      "paper=%d media=%d\n",
	      w, h,
	      header.HWResolution[0], header.HWResolution[1],
	      header.cupsBitsPerPixel, header.cupsColorSpace,
	      PaperCode, MediaCode);

	/* Allocate 1-bpp page buffer (16-byte aligned rows for JBIG) */
	bpl = (w + 7) / 8;
	bpl16 = (bpl + 15) & ~15;
	buf = calloc(bpl16, h);
	if (!buf)
	{
	    fprintf(stderr, "ERROR: rastertoxqx: Cannot allocate page "
		    "buffer (%u bytes)\n", bpl16 * h);
	    break;
	}

	/* Read raster and convert to 1-bpp packed bitmap */
	if (header.cupsColorSpace == CUPS_CSPACE_K &&
	    header.cupsBitsPerPixel == 1)
	{
	    /*
	     * K-1bpp: already 1-bit black, same as PBM format.
	     * Read directly into the page buffer.
	     */
	    for (y = 0; y < h; y++)
	    {
		cupsRasterReadPixels(ras, buf + (size_t)y * bpl16,
				     header.cupsBytesPerLine);
	    }
	}
	else if (header.cupsBitsPerPixel == 8)
	{
	    /*
	     * 8bpp grayscale (W or K): threshold to 1-bpp.
	     */
	    unsigned char *line = malloc(header.cupsBytesPerLine);
	    if (!line)
	    {
		fprintf(stderr, "ERROR: rastertoxqx: Cannot allocate "
			"line buffer\n");
		free(buf);
		break;
	    }
	    for (y = 0; y < h; y++)
	    {
		cupsRasterReadPixels(ras, line, header.cupsBytesPerLine);
		threshold_line(line, buf + (size_t)y * bpl16, w,
			       header.cupsColorSpace);
	    }
	    free(line);
	}
	else
	{
	    /*
	     * Unsupported format — drain the page data and skip.
	     */
	    unsigned char *discard = malloc(header.cupsBytesPerLine);
	    if (discard)
	    {
		for (y = 0; y < h; y++)
		    cupsRasterReadPixels(ras, discard,
					header.cupsBytesPerLine);
		free(discard);
	    }
	    fprintf(stderr, "ERROR: rastertoxqx: Unsupported raster "
		    "format (colorspace=%d, bpp=%d)\n",
		    header.cupsColorSpace, header.cupsBitsPerPixel);
	    free(buf);
	    continue;
	}

	/*
	 * Send the page (possibly multiple copies).
	 * pbm_page does not modify buf unless SaveToner is on.
	 */
	copies = (header.NumCopies > 0) ? header.NumCopies : 1;
	for (copy = 0; copy < copies; copy++)
	{
	    ++PageNum;
	    pbm_page(buf, w, h, stdout);
	}

	free(buf);
    }

    end_doc(stdout);
    cupsRasterClose(ras);

    return (PageNum > 0) ? 0 : 1;
}
