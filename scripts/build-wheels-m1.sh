# MUST be zsh or else python will label the wheel as x86
#!/usr/bin/zsh
set -e
pip install setuptools wheel
cd semgrep && python setup.py sdist bdist_wheel
# Zipping for a stable name to upload as an artifact
zip -r dist.zip dist
