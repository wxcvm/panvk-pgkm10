"""Read Android arm64 shared-library metadata without executing the binary."""
import struct


def inspect_elf(data):
    if data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<HH', data, 16) != (3, 183):
        raise ValueError('Expected little-endian ELF64 AArch64 ET_DYN')
    offset = struct.unpack_from('<Q', data, 40)[0]
    size, count, strings_index = struct.unpack_from('<HHH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * size) for i in range(count)]
    names_section = sections[strings_index]
    section_names = data[names_section[4]:names_section[4] + names_section[5]]

    def string_at(buffer, index):
        return buffer[index:buffer.index(b'\x00', index)].decode('ascii')

    contents = {string_at(section_names, s[0]): data[s[4]:s[4] + s[5]] for s in sections}
    strings = contents['.dynstr']
    symbols = contents['.dynsym']
    exports = set()
    for i in range(0, len(symbols), 24):
        name, info, visibility, section, _, _ = struct.unpack_from('<IBBHQQ', symbols, i)
        if section and info >> 4 in (1, 2) and visibility & 3 in (0, 3):
            exports.add(string_at(strings, name))
    needed = []
    for i in range(0, len(contents.get('.dynamic', b'')), 16):
        tag, value = struct.unpack_from('<qQ', contents['.dynamic'], i)
        if tag == 1:
            needed.append(string_at(strings, value))
    result = {'exports': sorted(exports), 'needed': needed}
    for section_name in ('.note.gnu.build-id', '.note.android.ident'):
        note = contents.get(section_name, b'')
        if len(note) < 12:
            continue
        name_size, desc_size, _ = struct.unpack_from('<III', note)
        desc_offset = 12 + ((name_size + 3) & ~3)
        descriptor = note[desc_offset:desc_offset + desc_size]
        if section_name == '.note.gnu.build-id':
            result['build_id'] = descriptor.hex()
        elif len(descriptor) >= 4:
            result['minimum_sdk'] = struct.unpack_from('<I', descriptor)[0]
    return result
