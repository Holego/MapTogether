extends MeshInstance3D
@export_storage var addon_data: Dictionary = {"topology": PackedInt32Array([0, 1, 2]), "label": "original"}
@export var linked_node: Node
