import queue

class Logger:
    def __init__(self, running_flag):
        self.queue = queue.Queue()
        self.running = running_flag

    def log(self, msg):
        self.queue.put(msg)

    def printer(self):
        while self.running() or not self.queue.empty():
            try:
                msg = self.queue.get(timeout=1)
                print(msg)
            except queue.Empty:
                continue
