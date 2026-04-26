# rom/

Place the Flommodore ROM binary here as `flommodore.rom`.

The ROM image is built in Block 12 from assembly source in `src/rom/`.
Until then, the emulator can be started without a ROM for testing
(the CPU will fetch open-bus $0000 from the ROM region).
