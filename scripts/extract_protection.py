import re
import sys

src = open(sys.argv[1], encoding='utf-8').read()
names = [
    'SYSTEM_CRITICAL_BUNDLES',
    'APPLE_UNINSTALLABLE_APPS',
    'ENDPOINT_SECURITY_BUNDLE_PREFIXES',
    'DATA_PROTECTED_BUNDLES',
]
out = [
    '// Generated from Mole lib/core/app_protection_data.sh (GPL-3.0, https://github.com/tw93/Mole).',
    '// Do not edit by hand; regenerate with scripts/extract_protection.py.',
    '',
    'enum ProtectionData {',
]
for n in names:
    m = re.search(r'readonly ' + n + r'=\((.*?)\n\)', src, re.S)
    items = re.findall(r'^\s*"([^"]*)"', m.group(1), re.M)
    swift_name = {
        'SYSTEM_CRITICAL_BUNDLES': 'systemCriticalBundles',
        'APPLE_UNINSTALLABLE_APPS': 'appleUninstallableApps',
        'ENDPOINT_SECURITY_BUNDLE_PREFIXES': 'endpointSecurityBundlePrefixes',
        'DATA_PROTECTED_BUNDLES': 'dataProtectedBundles',
    }[n]
    out.append(f'    static let {swift_name}: [String] = [')
    for it in items:
        out.append('        ' + '"' + it.replace('\\', '\\\\').replace('"', '\\"') + '",')
    out.append('    ]')
    print(n, len(items), file=sys.stderr)
out.append('}')
print('\n'.join(out))
