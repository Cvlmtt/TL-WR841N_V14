FROM ubuntu:22.04

# Set frontend to noninteractive to avoid prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies: tcpdump for the STREAM command and net-tools for debugging
RUN apt-get update && apt-get install -y tcpdump net-tools && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the pre-compiled client and rename it
COPY c2_client_x86 c2_client

# Copy the wrapper script
COPY run_client.sh .

# Make them executable
RUN chmod +x c2_client run_client.sh
