#!/usr/bin/env python3
"""An ssh-agent that lists one key and never answers a request to sign with it."""
import base64
import socket
import struct
import sys
import time

SOCKET, PUBLIC_KEY = sys.argv[1:3]
IDENTITIES_REQUEST, IDENTITIES_ANSWER, FAILURE = 11, 12, 5
SIGN_REQUEST = 13

with open(PUBLIC_KEY, encoding="utf-8") as key_file:
    blob = base64.b64decode(key_file.read().split()[1])


def string(value):
    return struct.pack(">I", len(value)) + value


def serve(connection):
    while True:
        header = connection.recv(4, socket.MSG_WAITALL)
        if len(header) < 4:
            return
        body = connection.recv(struct.unpack(">I", header)[0], socket.MSG_WAITALL)
        if body[0] == SIGN_REQUEST:
            time.sleep(600)
        if body[0] == IDENTITIES_REQUEST:
            answer = bytes([IDENTITIES_ANSWER]) + struct.pack(">I", 1) + string(blob) + string(b"stalling")
        else:
            answer = bytes([FAILURE])
        connection.sendall(struct.pack(">I", len(answer)) + answer)


with socket.socket(socket.AF_UNIX) as server:
    server.bind(SOCKET)
    server.listen()
    while True:
        accepted, _ = server.accept()
        serve(accepted)
