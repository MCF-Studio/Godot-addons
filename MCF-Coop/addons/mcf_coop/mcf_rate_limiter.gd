class_name McfRateLimiter
extends RefCounted
## Seau à jetons par connexion : limite les paquets et les octets par seconde (menace : inondation).
## `allow(size)` renvoie faux quand un pair dépasse son budget ; l'appelant compte les refus et coupe le pair s'il insiste.

var packets_per_second: float
var bytes_per_second: float
## Rafale tolérée (en secondes de débit) avant de refuser.
var burst_seconds: float

var _packets: float
var _bytes: float


func _init(p_packets_per_second: float = 90.0, p_bytes_per_second: float = 24000.0, p_burst_seconds: float = 1.0) -> void:
	packets_per_second = p_packets_per_second
	bytes_per_second = p_bytes_per_second
	burst_seconds = p_burst_seconds
	_packets = packets_per_second * burst_seconds
	_bytes = bytes_per_second * burst_seconds


func refill(delta: float) -> void:
	_packets = minf(_packets + packets_per_second * delta, packets_per_second * burst_seconds)
	_bytes = minf(_bytes + bytes_per_second * delta, bytes_per_second * burst_seconds)


func allow(size: int) -> bool:
	if _packets < 1.0 or _bytes < float(size):
		return false
	_packets -= 1.0
	_bytes -= float(size)
	return true
