/* SPDX-License-Identifier: MIT */
/* ALT RPM 4.13 rejects the optional SHA256 header digest (tag 273).
 * Adapt unsigned packages before signing, preserving the main header/payload.
 * Header mutation and serialization belong to librpm, not a private encoder.
 */
#include <arpa/inet.h>
#include <rpm/header.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  unsigned char prefix[112], buffer[65536];
  unsigned int size;
  uint32_t count, bytes;
  if (argc != 3)
    return 2;
  FILE *in = fopen(argv[1], "rb"), *out = fopen(argv[2], "wb");
  if (!in || !out || fread(prefix, 1, sizeof(prefix), in) != sizeof(prefix))
    return 1;
  if (memcmp(prefix, "\xed\xab\xee\xdb", 4) ||
      memcmp(prefix + 96, "\x8e\xad\xe8\x01", 4))
    return 1;
  memcpy(&count, prefix + 104, 4);
  memcpy(&bytes, prefix + 108, 4);
  size_t length = 8ULL + 16ULL * ntohl(count) + ntohl(bytes);
  if (length > 16 * 1024 * 1024)
    return 1;
  unsigned char *blob = malloc(length);
  if (!blob)
    return 1;
  memcpy(blob, prefix + 104, 8);
  if (fread(blob + 8, 1, length - 8, in) != length - 8)
    return 1;
  Header header = headerImport(blob, length, HEADERIMPORT_COPY);
  free(blob);
  if (!header)
    return 1;
  /* Refuse signed inputs: publishers must sign the resulting artifact. */
  if (headerIsEntry(header, 268) || headerIsEntry(header, 267) ||
      headerIsEntry(header, 1002) || headerIsEntry(header, 1005))
    return 1;
  Header copy = headerCopy(header);
  headerFree(header);
  header = copy;
  if (!header)
    return 1;
  headerDel(header, 273);
  header = headerReload(header, RPMTAG_HEADERSIGNATURES);
  if (!header)
    return 1;
  blob = headerExport(header, &size);
  headerFree(header);
  if (!blob || fwrite(prefix, 1, 104, out) != 104 ||
      fwrite(blob, 1, size, out) != size)
    return 1;
  free(blob);
  for (size_t i = (104ULL + size) % 8; i && i < 8; ++i)
    if (fputc(0, out) == EOF)
      return 1;
  size_t oldEnd = 104 + length;
  if (fseek(in, (8 - oldEnd % 8) % 8, SEEK_CUR))
    return 1;
  size_t n;
  while ((n = fread(buffer, 1, sizeof(buffer), in)))
    if (fwrite(buffer, 1, n, out) != n)
      return 1;
  if (ferror(in) || fclose(in) || fclose(out))
    return 1;
  return 0;
}
