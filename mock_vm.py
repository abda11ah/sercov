# mock_vm.py - Save and run: python3 mock_vm.py
import socket
import time


def mock_vm_serial():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 4557))
    server.listen(1)
    print("Mock VM Serial Console listening on port 4555...")

    while True:
        client, addr = server.accept()
        print(f"Connection from {addr}")
        client.send(b"Mock VM Boot Complete\r\nLogin: ")

        while True:
            try:
                data = client.recv(1024)
                if not data:
                    break
                command = data.decode().strip()
                print(f"VM received: {command}")
                if command == "exit":
                    client.send(b"Goodbye!\r\n")
                    break
                else:
                    response = f"Command '{command}' executed\r\nVM> "
                    client.send(response.encode())
            except:
                break
        client.close()


if __name__ == "__main__":
    mock_vm_serial()
