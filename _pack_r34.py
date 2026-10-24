import io
import os
import subprocess
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = ROOT
DELIV = os.path.join(REPO, "deliverable")
os.makedirs(DELIV, exist_ok=True)

# --- 源码包：按 git 树取，避免把 build/临时文件带进去 ---
out = subprocess.run(["git", "-c", "core.quotepath=false", "ls-tree", "-r", "--name-only", "HEAD"],
                     cwd=REPO, capture_output=True, text=True).stdout.splitlines()
src_zip = os.path.join(DELIV, "GuanpanAdvisor-source-r34.zip")
count = 0
with zipfile.ZipFile(src_zip, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in out:
        path = os.path.join(REPO, rel.replace("/", os.sep))
        if not os.path.isfile(path):
            continue
        z.write(path, rel)
        count += 1
print("source:", src_zip, count, "files", os.path.getsize(src_zip), "bytes")

# --- NAS 部署包：只打运行需要的文件，前台目录压平到包根 ---
DEPLOY = [
    ".env.example", "compose.yml", "README-NAS.md", "update.sh",
    "server/app.py", "server/crossmarket.py", "server/diagnose.py", "server/Dockerfile",
    "server/domain.py", "server/market.py", "server/news.py", "server/research.py",
    "server/start.sh", "server/VERSION", "server/workers.py",
    "server/web/index.html", "server/web/market.html",
]
base = os.path.join(REPO, "GuanpanNext")
dep_zip = os.path.join(DELIV, "nas-advisor-deploy-r34.zip")
missing = []
with zipfile.ZipFile(dep_zip, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in DEPLOY:
        path = os.path.join(base, rel.replace("/", os.sep))
        if not os.path.isfile(path):
            missing.append(rel)
            continue
        z.write(path, rel)
print("deploy:", dep_zip, len(DEPLOY) - len(missing), "files", os.path.getsize(dep_zip), "bytes",
      "missing:", missing)
