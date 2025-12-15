#!/bin/bash
mipsel-linux-gcc -Os -static -s -Wl,--gc-sections -ffunction-sections -fdata-sections -o c2_client c2_client.c 
mipsel-linux-strip --strip-all c2_client
