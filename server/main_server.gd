# server/main_server.gd
extends Node

const WSServer = preload("res://server/net/ws_server.gd")
const WorldInstance = preload("res://server/world/world_instance.gd")
const TickLoop = preload("res://server/sim/tick_loop.gd")

var _ws_server
var _world
var _tick_loop

func _ready() -> void:
    print("[Server] Booting on port %d" % Constants.SERVER_PORT)
    var boot_seed: int = int(Time.get_unix_time_from_system())
    _world = WorldInstance.new(boot_seed)
    add_child(_world)

    _ws_server = WSServer.new()
    add_child(_ws_server)
    _ws_server.set_world(_world)
    _ws_server.listen(Constants.SERVER_PORT)

    _tick_loop = TickLoop.new()
    add_child(_tick_loop)
    _tick_loop.set_world(_world)
    _tick_loop.set_ws_server(_ws_server)
    _tick_loop.start()

    print("[Server] Ready. World seed: %d" % boot_seed)
