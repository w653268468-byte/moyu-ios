"""Check the Mach-O entitlements used by Xcode's iOS Simulator runtime.

Xcode embeds simulated entitlements in __TEXT,__entitlements; the ad-hoc
codesign entitlement blob may legitimately be empty. Device signing is separate.
"""
import argparse
import plistlib
import struct
from pathlib import Path


def read_entitlements(binary):
    data = binary.read_bytes()
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a little-endian 64-bit simulator Mach-O')
    commands = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    for _ in range(commands):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Invalid Mach-O load command')
        if command == 0x19:
            count = struct.unpack_from('<I', data, offset + 64)[0]
            if 72 + count * 80 > size:
                raise ValueError('Invalid Mach-O section count')
            for index in range(count):
                section = offset + 72 + index * 80
                name = data[section:section + 16].rstrip(b'\0')
                segment = data[section + 16:section + 32].rstrip(b'\0')
                if (segment, name) == (b'__TEXT', b'__entitlements'):
                    length, position = struct.unpack_from('<QI', data, section + 40)
                    if length > 1024 * 1024 or position + length > len(data):
                        raise ValueError('Invalid entitlement section size')
                    return plistlib.loads(data[position:position + length].rstrip(b'\0'))
        offset += size
    raise ValueError('Simulator entitlement section is missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    values = read_entitlements(args.app / info['CFBundleExecutable'])
    assert values['application-identifier'] == 'GAVINCI001.org.moyu.reader', values
    assert values['keychain-access-groups'] == ['GAVINCI001.org.moyu.reader'], values
    args.output.write_bytes(plistlib.dumps(values))
    print('Simulator embedded application identity and keychain access group verified')


if __name__ == '__main__':
    main()
