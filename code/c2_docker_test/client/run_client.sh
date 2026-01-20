#!/bin/sh
# The c2_client application daemonizes, so the container would exit.
# We launch the client and then wait indefinitely to keep the container running.
./c2_client

# Keep the container alive.
tail -f /dev/null
