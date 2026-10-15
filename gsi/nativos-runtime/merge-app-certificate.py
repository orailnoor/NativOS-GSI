"""Merge only the verified NativOS signer/package into an existing policy XML."""
import base64
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

apksigner, apk, original, output = sys.argv[1:]
result = subprocess.run([apksigner, "verify", "--print-certs-pem", apk],
                        check=True, capture_output=True, text=True)
certificates = re.findall(r"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----",
                          result.stdout, flags=re.S)
if len(certificates) != 1:
    raise SystemExit("Expected exactly one signing certificate")
certificate = base64.b64decode("".join(certificates[0].split()), validate=True)
if hashlib.sha256(certificate).hexdigest() != "fb03fe960e3c3e75c875af85406cc0088f0022983e80d747b69425848653d2a0":
    raise SystemExit("APK signing identity differs from the approved NativOS key")
tree = ET.parse(original)
root = tree.getroot()
if root.tag != "policy":
    raise SystemExit("Unexpected mac_permissions XML root")
signature = certificate.hex()
if any(s.get("signature") == signature for s in root.findall("signer")):
    raise SystemExit("Signer already exists; review rather than duplicate its policy")
signer = ET.SubElement(root, "signer", signature=signature)
package = ET.SubElement(signer, "package", name="com.nativOS")
ET.SubElement(package, "seinfo", value="nativos")
ET.indent(tree)
tree.write(Path(output), encoding="utf-8", xml_declaration=True)
print("Merged certificate-bound NativOS seinfo; other signer entries preserved")
