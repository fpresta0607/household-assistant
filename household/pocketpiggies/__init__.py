"""The PocketPiggies key holder: one host service per assistant, outside its gateway.

The gateway runs the model and every tool it drives as one uid, so any file or
environment value the gateway can read, the model's shell can copy. The client
credential and the owner's read grant therefore live here, under another uid, in a
directory no container mounts. The gateway reaches this service only through a Unix
socket in its own state directory and gets back read results and link messages,
never a credential.
"""
