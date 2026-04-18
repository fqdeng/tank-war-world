# common/protocol/message_types.gd
class_name MessageType

# Binary message type IDs. Stable values — never reorder; only append.
enum {
    CONNECT = 0,         # client → server
    CONNECT_ACK = 1,     # server → client
    INPUT = 2,           # client → server (20 Hz)
    SNAPSHOT = 3,        # server → client (20 Hz)
    FIRE = 4,            # client → server
    SHELL_SPAWNED = 5,   # server → all clients (was SHELL_FIRED in Plan 01)
    HIT = 6,             # server → all clients
    DEATH = 7,           # server → all clients
    RESPAWN = 8,         # server → affected client
    PING = 9,            # server → client
    PONG = 10,           # client → server
    DISCONNECT = 11,     # either direction
    OBSTACLE_DESTROYED = 12,  # server → all clients
}
