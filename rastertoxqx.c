/*
 * rastertoxqx.c — CUPS raster filter for HP LaserJet P1007
 *
 * Converts CUPS raster input to Zenographics XQX format with JBIG2
 * compression. Designed to work with macOS's built-in cgpdftoraster
 * filter, eliminating the need for Ghostscript entirely.
 *
 * Pipeline: PDF → cgpdftoraster (macOS built-in) → rastertoxqx → printer
 *
 * Based on foo2xqx from the foo2zjs project by Rick Richardson.
 * Rewritten as a native CUPS raster filter by Anish.
 *
 * License: GPL v2 or later (same as foo2zjs)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <cups/cups.h>
#include <cups/raster.h>
#include "jbig.h"
#include "xqx.h"

/* ---------- XQX output helpers (from foo2xqx.c) ---------- */

static void
chunk_write(unsigned long type, unsigned long items, FILE *fp)
{
    XQX_HEADER chunk;
    chunk.type = be32(type);
    chunk.items = be32(items);
    if (fwrite(&chunk, 1, sizeof(XQX_HEADER), fp) == 0)
    {
        fprintf(stderr, "ERROR: rastertoxqx: chunk_write failed\n");
        exit(1);
    }
}

static void
item_uint32_write(unsigned long item, unsigned long value, FILE *fp)
{
    XQX_ITEM_UINT32 rec;
    rec.header.type = be32(item);
    rec.header.size = be32(sizeof(DWORD));
    rec.value = be32(value);
    if (fwrite(&rec, 1, sizeof(XQX_ITEM_UINT32), fp) == 0)
    {
        fprintf(stderr, "ERROR: rastertoxqx: item_uint32_write failed\n");
        exit(1);
    }
}

static void
item_bytelut_write(unsigned long item, unsigned long len, BYTE *buf, FILE *fp)
{
    XQX_ITEM_HEADER header;
    header.type = be32(item);
    header.size = be32(len);
    if (fwrite(&header, 1, sizeof(XQX_ITEM_HEADER), fp) == 0 ||
        fwrite(buf, 1, len, fp) == 0)
    {
        fprintf(stderr, "ERROR: rastertoxqx: item_bytelut_write failed\n");
        exit(1);
    }
}

/* ---------- JBIG compressed data chain ---------- */

typedef struct _BIE_CHAIN {
    unsigned char   *data;
    size_t          len;
    struct _BIE_CHAIN *next;
} BIE_CHAIN;

static void
free_chain(BIE_CHAIN *chain)
{
    BIE_CHAIN *next;
    next = chain;
    while ((chain = next))
    {
        next = chain->next;
        if (chain->data)
            free(chain->data);
        free(chain);
    }
}

/* JBIG encoding parameters — must match what the printer expects */
static long JbgOptions[5] = {
    JBG_ILEAVE | JBG_SMID,                                         /* Order */
    JBG_DELAY_AT | JBG_LRLTWO | JBG_TPDON | JBG_TPBON | JBG_DPON, /* Options */
    128,                                                            /* L0 */
    16,                                                             /* MX */
    0                                                               /* MY */
};

/*
 * JBIG output callback — builds a linked list of compressed data.
 * First item is always the 20-byte BIH. Subsequent items are 64KB max.
 */
static void
output_jbig(unsigned char *start, size_t len, void *cbarg)
{
    BIE_CHAIN *current, **root = (BIE_CHAIN **)cbarg;
    int size = 65536;

    if (*root == NULL)
    {
        *root = malloc(sizeof(BIE_CHAIN));
        if (!*root)
        {
            fprintf(stderr, "ERROR: rastertoxqx: malloc failed\n");
            exit(1);
        }
        (*root)->data = NULL;
        (*root)->next = NULL;
        (*root)->len = 0;
        size = 20;
    }

    current = *root;
    while (current->next)
        current = current->next;

    while (len > 0)
    {
        int amt, left;

        if (!current->data)
        {
            current->data = malloc(size);
            if (!current->data)
            {
                fprintf(stderr, "ERROR: rastertoxqx: malloc failed\n");
                exit(1);
            }
        }

        left = size - current->len;
        amt = (len > (size_t)left) ? left : (int)len;
        memcpy(current->data + current->len, start, amt);
        current->len += amt;
        len -= amt;
        start += amt;

        if (current->len == (size_t)size)
        {
            current->next = malloc(sizeof(BIE_CHAIN));
            if (!current->next)
            {
                fprintf(stderr, "ERROR: rastertoxqx: malloc failed\n");
                exit(1);
            }
            current = current->next;
            current->data = NULL;
            current->next = NULL;
            current->len = 0;
        }
    }
}

/* ---------- XQX page/plane output ---------- */

static int
write_plane(int planeNum, BIE_CHAIN **root, FILE *fp)
{
    BIE_CHAIN *current = *root;
    int first;
    BYTE *bih;

    if (!current || !current->next || current->len != 20)
    {
        fprintf(stderr, "ERROR: rastertoxqx: invalid JBIG data\n");
        return 1;
    }

    bih = current->data;
    first = 1;
    for (current = *root; current && current->len; current = current->next)
    {
        if (current == *root)
            continue;

        chunk_write(XQX_START_PLANE, 4, fp);
        item_uint32_write(0x80000000, first ? 64 : 48, fp);
        item_uint32_write(0x40000000, 0, fp);
        if (first)
            item_bytelut_write(XQXI_BIH, 20, bih, fp);
        else
            item_uint32_write(0x40000003, 1, fp);
        item_uint32_write(XQXI_END, 0xdeadbeef, fp);

        chunk_write(XQX_JBIG, current->len, fp);
        if (current->len)
        {
            if (fwrite(current->data, 1, current->len, fp) == 0)
            {
                fprintf(stderr, "ERROR: rastertoxqx: write JBIG data failed\n");
                return 1;
            }
        }

        chunk_write(XQX_END_PLANE, 0, fp);
        first = 0;
    }

    free_chain(*root);
    return 0;
}

static void
start_doc(FILE *fp, int density, int economode)
{
    char header[4] = ",XQX";
    time_t now;
    struct tm *tmp;
    char datetime[14 + 1];

    now = time(NULL);
    tmp = localtime(&now);
    strftime(datetime, sizeof(datetime), "%Y%m%d%H%M%S", tmp);

    fprintf(fp, "\033%%-12345X@PJL JOB\n");
    fprintf(fp, "@PJL SET JAMRECOVERY=OFF\n");
    fprintf(fp, "@PJL SET DENSITY=%d\n", density);
    fprintf(fp, "@PJL SET ECONOMODE=%s\n", economode ? "ON" : "OFF");
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

    chunk_write(XQX_START_DOC, 7, fp);
    item_uint32_write(0x80000000, 84, fp);
    item_uint32_write(0x10000005, 1, fp);
    item_uint32_write(0x10000001, 0, fp);
    item_uint32_write(XQXI_DMDUPLEX, 0, fp);   /* duplex off */
    item_uint32_write(0x10000000, 0, fp);
    item_uint32_write(0x10000003, 1, fp);
    item_uint32_write(XQXI_END, 0xdeadbeef, fp);
}

static void
end_doc(FILE *fp)
{
    chunk_write(XQX_END_DOC, 0, fp);
    fprintf(fp, "\033%%-12345X@PJL EOJ\n");
    fprintf(fp, "\033%%-12345X");
}

static void
start_page(FILE *fp, int resX, int resY, int bpp,
           unsigned long rasterW, unsigned long rasterH,
           int realWidth,
           int paperCode, int mediaCode, int sourceCode,
           int economode)
{
    chunk_write(XQX_START_PAGE, 15, fp);
    item_uint32_write(0x80000000, 180, fp);
    item_uint32_write(0x20000005, 1, fp);
    item_uint32_write(XQXI_DMDEFAULTSOURCE, sourceCode, fp);
    item_uint32_write(XQXI_DMMEDIATYPE, mediaCode, fp);
    item_uint32_write(0x20000007, 1, fp);
    item_uint32_write(XQXI_RESOLUTION_X, resX, fp);
    item_uint32_write(XQXI_RESOLUTION_Y, resY, fp);
    item_uint32_write(XQXI_RASTER_X, rasterW, fp);
    item_uint32_write(XQXI_RASTER_Y, rasterH, fp);
    item_uint32_write(XQXI_VIDEO_BPP, bpp, fp);
    item_uint32_write(XQXI_VIDEO_X, realWidth / bpp, fp);
    item_uint32_write(XQXI_VIDEO_Y, rasterH, fp);
    item_uint32_write(XQXI_ECONOMODE, economode, fp);
    item_uint32_write(XQXI_DMPAPER, paperCode, fp);
    item_uint32_write(XQXI_END, 0xdeadbeef, fp);
}

static void
end_page(FILE *fp)
{
    chunk_write(XQX_END_PAGE, 0, fp);
}

/* ---------- Mapping functions ---------- */

static int
map_paper_code(const char *name)
{
    if (!name || !name[0])
        return DMPAPER_LETTER;

    if (strcmp(name, "Letter") == 0)       return DMPAPER_LETTER;
    if (strcmp(name, "Legal") == 0)        return DMPAPER_LEGAL;
    if (strcmp(name, "Executive") == 0)    return DMPAPER_EXECUTIVE;
    if (strcmp(name, "A4") == 0)           return DMPAPER_A4;
    if (strcmp(name, "A5") == 0)           return DMPAPER_A5;
    if (strcmp(name, "B5") == 0)           return DMPAPER_B5;
    if (strcmp(name, "Env10") == 0)        return DMPAPER_ENV_10;
    if (strcmp(name, "EnvDL") == 0)        return DMPAPER_ENV_DL;
    if (strcmp(name, "EnvC5") == 0)        return DMPAPER_ENV_C5;
    if (strcmp(name, "EnvMonarch") == 0)   return DMPAPER_ENV_MONARCH;

    return DMPAPER_LETTER;
}

static int
map_media_code(const char *media)
{
    if (!media || !media[0])
        return DMMEDIA_PLAIN;

    if (strcmp(media, "Plain") == 0)         return DMMEDIA_PLAIN;
    if (strcmp(media, "Transparency") == 0)  return DMMEDIA_TRANSPARENCY;
    if (strcmp(media, "Envelope") == 0)      return DMMEDIA_ENVELOPE;
    if (strcmp(media, "Labels") == 0)        return DMMEDIA_LABELS;
    if (strcmp(media, "Heavy") == 0)         return DMMEDIA_HEAVY;
    if (strcmp(media, "Letterhead") == 0)    return DMMEDIA_LETTERHEAD;

    return DMMEDIA_PLAIN;
}

static int
map_source_code(unsigned media_position)
{
    switch (media_position)
    {
    case 1:  return DMBIN_TRAY1;
    case 4:  return DMBIN_MANUAL;
    default: return DMBIN_AUTO;
    }
}

/* ---------- CUPS options parsing ---------- */

static void
parse_options(const char *options, int *density, int *economode)
{
    cups_option_t *opts = NULL;
    int num_opts;
    const char *val;

    if (!options || !options[0])
        return;

    num_opts = cupsParseOptions(options, 0, &opts);

    val = cupsGetOption("Density", num_opts, opts);
    if (val)
    {
        int d = atoi(val);
        if (d >= 1 && d <= 5)
            *density = d;
    }

    val = cupsGetOption("Quality", num_opts, opts);
    if (val && strcmp(val, "draft") == 0)
        *economode = 1;

    val = cupsGetOption("EconoMode", num_opts, opts);
    if (val && strcmp(val, "on") == 0)
        *economode = 1;

    cupsFreeOptions(num_opts, opts);
}

/* ---------- Signal handling ---------- */

static volatile int Canceled = 0;

static void
cancel_handler(int sig)
{
    (void)sig;
    Canceled = 1;
}

/* ---------- Main ---------- */

int
main(int argc, char *argv[])
{
    cups_raster_t       *ras;
    cups_page_header2_t header;
    int                 fd;
    int                 page = 0;
    int                 density = 3;
    int                 economode = 0;

    /* CUPS filter expects: filter job user title copies options [file] */
    if (argc < 6 || argc > 7)
    {
        fprintf(stderr, "Usage: %s job user title copies options [file]\n",
                argv[0]);
        return 1;
    }

    /* Set up signal handlers for clean cancellation */
    signal(SIGTERM, cancel_handler);
    signal(SIGPIPE, SIG_IGN);

    /* Parse options not carried by the raster header */
    parse_options(argv[5], &density, &economode);

    /* Open input */
    if (argc == 7)
    {
        fd = open(argv[6], O_RDONLY);
        if (fd < 0)
        {
            fprintf(stderr, "ERROR: rastertoxqx: cannot open %s\n", argv[6]);
            return 1;
        }
    }
    else
    {
        fd = 0; /* stdin */
    }

    /* Open CUPS raster stream */
    ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (!ras)
    {
        fprintf(stderr, "ERROR: rastertoxqx: cannot open raster stream\n");
        if (fd != 0)
            close(fd);
        return 1;
    }

    /* Write XQX document header */
    start_doc(stdout, density, economode);

    /* Process each page */
    while (!Canceled && cupsRasterReadHeader2(ras, &header))
    {
        unsigned int    cupsW, cupsH, cupsBpl;
        int             resX, resY, bpp;
        int             jbigW, realWidth;
        int             bpl, bpl16;
        unsigned char   *buf;
        unsigned char   *bitmaps[1];
        struct jbg_enc_state se;
        BIE_CHAIN       *chain = NULL;
        int             paperCode, mediaCode, sourceCode;
        unsigned int    y;
        int             invert;

        page++;

        /* Extract raster dimensions */
        cupsW   = header.cupsWidth;
        cupsH   = header.cupsHeight;
        cupsBpl = header.cupsBytesPerLine;
        resX    = header.HWResolution[0];
        resY    = header.HWResolution[1];

        fprintf(stderr, "DEBUG: rastertoxqx: page %d, %ux%u pixels, %dx%d dpi, colorspace %d\n",
                page, cupsW, cupsH, resX, resY, header.cupsColorSpace);

        /* Validate — we only handle 1bpp monochrome */
        if (header.cupsBitsPerPixel != 1)
        {
            fprintf(stderr, "ERROR: rastertoxqx: expected 1bpp, got %d\n",
                    header.cupsBitsPerPixel);
            break;
        }

        /* Determine if we need to invert (CUPS_CSPACE_W = white is 1) */
        invert = (header.cupsColorSpace == CUPS_CSPACE_W);

        /* Resolution: XQX always reports 600 for X, uses BPP as multiplier */
        bpp = resX / 600;
        if (bpp < 1) bpp = 1;

        /* Map CUPS header → XQX codes */
        paperCode  = map_paper_code(header.cupsPageSizeName);
        mediaCode  = map_media_code(header.MediaType);
        sourceCode = map_source_code(header.MediaPosition);

        /* Width padding for JBIG: round up to 128-pixel boundary */
        realWidth = cupsW;
        jbigW = (cupsW + 127) & ~127;
        bpl   = (jbigW + 7) / 8;
        bpl16 = (bpl + 15) & ~15;

        /* Allocate page buffer (zero-filled for padding) */
        buf = calloc(bpl16, cupsH);
        if (!buf)
        {
            fprintf(stderr, "ERROR: rastertoxqx: cannot allocate page buffer (%u bytes)\n",
                    bpl16 * cupsH);
            break;
        }

        /* Read raster scanlines into padded buffer */
        for (y = 0; y < cupsH && !Canceled; y++)
        {
            unsigned int n = cupsRasterReadPixels(ras,
                                                  buf + (size_t)y * bpl16,
                                                  cupsBpl);
            if (n == 0)
                break;

            /* Invert if colorspace is white-is-1 */
            if (invert)
            {
                unsigned int i;
                unsigned char *row = buf + (size_t)y * bpl16;
                for (i = 0; i < cupsBpl; i++)
                    row[i] ^= 0xFF;
            }
        }

        if (Canceled)
        {
            free(buf);
            break;
        }

        /* JBIG2 encode the page */
        *bitmaps = buf;
        jbg_enc_init(&se, jbigW, cupsH, 1, bitmaps, output_jbig, &chain);
        jbg_enc_options(&se, JbgOptions[0], JbgOptions[1],
                        JbgOptions[2], JbgOptions[3], JbgOptions[4]);
        jbg_enc_out(&se);
        jbg_enc_free(&se);

        /* Write XQX page */
        start_page(stdout, 600, resY, bpp,
                   jbigW, cupsH, realWidth,
                   paperCode, mediaCode, sourceCode,
                   economode);
        write_plane(4, &chain, stdout);
        end_page(stdout);

        free(buf);

        /* CUPS page accounting */
        fprintf(stderr, "PAGE: %d %d\n", page,
                header.NumCopies > 0 ? header.NumCopies : 1);
    }

    /* Write XQX document trailer */
    end_doc(stdout);

    /* Cleanup */
    cupsRasterClose(ras);
    if (fd != 0)
        close(fd);

    return Canceled ? 1 : 0;
}
