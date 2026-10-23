#include "IOSHDRVideo.h"
#include <cassert>
#include <cmath>
#include <iostream>

int main()
{
  IOSHDRVideoMetadata metadata;
  assert(std::abs(IOSHDRContentHeadroom(metadata) - 1000.0 / 203.0) < 1e-9);
  metadata.hasMastering = true;
  // ST2086: 4000 nit mastering display, stored in 0.0001 nit units.
  metadata.mastering[16] = 0x02;
  metadata.mastering[17] = 0x62;
  metadata.mastering[18] = 0x5a;
  metadata.mastering[19] = 0x00;
  assert(std::abs(IOSHDRContentHeadroom(metadata) - 4000.0 / 203.0) < 1e-9);
  metadata.hasLight = true;
  metadata.light = {0x03, 0xe8, 0x00, 0x64}; // MaxCLL1000, MaxFALL100
  assert(std::abs(IOSHDRContentHeadroom(metadata) - 1000.0 / 203.0) < 1e-9);
  metadata.light = {0x00, 0x64, 0x00, 0x32};
  assert(IOSHDRContentHeadroom(metadata) == 1.0);
  metadata.light = {0xff, 0xff, 0x00, 0x32};
  assert(IOSHDRContentHeadroom(metadata) == 10000.0 / 203.0);
  metadata.light = {};
  assert(std::abs(IOSHDRContentHeadroom(metadata) - 4000.0 / 203.0) < 1e-9);
  std::cout << "PASS: HDR peak metadata, big-endian units, MaxCLL precedence, SDR floor, fallback and limit\n";
}
