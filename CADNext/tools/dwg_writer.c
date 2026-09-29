// Standalone optional LibreDWG backend. All arguments and SAT files are staged by
// DwgWriter.cpp; the GUI validates the result before replacing the destination.
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dwg.h>
#include <dwg_api.h>

static char *read_sat(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    if (fseek(file, 0, SEEK_END)) { fclose(file); return NULL; }
    const long size = ftell(file);
    if (size < 4 || size > 256L * 1024 * 1024 || fseek(file, 0, SEEK_SET)) { fclose(file); return NULL; }
    char *bytes = (char *)calloc((size_t)size + 1, 1);
    if (!bytes) { fclose(file); return NULL; }
    const size_t read = fread(bytes, 1, (size_t)size, file);
    fclose(file);
    if (read != (size_t)size || memcmp(bytes, "700 ", 4) || memchr(bytes, 0, read)) { free(bytes); return NULL; }
    *length = read;
    return bytes;
}

static int set_sat_blocks(Dwg_Entity_3DSOLID *solid, const size_t length) {
    // LibreDWG 0.13.4 resets the ACIS offset after each 4096-byte block, and
    // gives the last block size zero for exact multiples. Rebuild the encrypted
    // blocks from absolute offsets; this also works with versions fixing the API.
    for (unsigned i = 0; i < solid->num_blocks; ++i) {
        const size_t offset = (size_t)i * 4096;
        const size_t count = length - offset < 4096 ? length - offset : 4096;
        free(solid->encr_sat_data[i]);
        solid->block_size[i] = (BITCODE_BL)count;
        int used = 0;
        solid->encr_sat_data[i] = dwg_encrypt_SAT1((BITCODE_BL)count, solid->acis_data + offset, &used);
        if (!solid->encr_sat_data[i] || used != (int)count) return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 9 || argc > 4104) { fprintf(stderr, "Usage: cadnext_dwg_writer output.dwg minx miny minz maxx maxy maxz body.sat ...\n"); return 2; }
    double bounds[6];
    for (int i = 0; i < 6; ++i) {
        char *end = NULL; errno = 0;
        bounds[i] = strtod(argv[i + 2], &end);
        if (errno || !end || *end || !isfinite(bounds[i])) { fprintf(stderr, "Invalid DWG extents\n"); return 2; }
    }
    for (int i = 0; i < 3; ++i) if (bounds[i] > bounds[i + 3]) return 2;
    Dwg_Data *document = dwg_new_Document(R_2000, 0, 0);
    if (!document) return 2;
    document->header_vars.INSUNITS = 4;
    document->header_vars.EXTMIN.x = bounds[0]; document->header_vars.EXTMIN.y = bounds[1]; document->header_vars.EXTMIN.z = bounds[2];
    document->header_vars.EXTMAX.x = bounds[3]; document->header_vars.EXTMAX.y = bounds[4]; document->header_vars.EXTMAX.z = bounds[5];
    int status = 2;
    size_t total = 0;
    for (int i = 8; i < argc; ++i) {
        size_t length = 0;
        char *sat = read_sat(argv[i], &length);
        total += length;
        if (!sat || total > 256L * 1024 * 1024) { free(sat); fprintf(stderr, "Cannot read SAT body, or export exceeds 256 MiB\n"); goto finish; }
        // Adding objects can reallocate the document's object array. Resolve the
        // model-space header again for every body.
        Dwg_Object *model = dwg_model_space_object(document);
        Dwg_Entity_3DSOLID *solid = model ? dwg_add_3DSOLID(model->tio.object->tio.BLOCK_HEADER, sat) : NULL;
        free(sat);
        if (!solid || !set_sat_blocks(solid, length)) { fprintf(stderr, "Cannot add DWG 3DSOLID\n"); goto finish; }
    }
    status = dwg_write_file(argv[1], document);
    if (status) fprintf(stderr, "LibreDWG write error: %d\n", status);
finish:
    dwg_free(document);
    free(document);
    return status != 0;
}
