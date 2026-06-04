#!/usr/bin/env python3
import argparse
from pathlib import Path
import shutil
from datetime import datetime

def main():
    p = argparse.ArgumentParser()
    p.add_argument('slug')
    p.add_argument('--source')
    p.add_argument('--date', default=datetime.utcnow().strftime('%Y%m%d'))
    p.add_argument('--base', default='bggg-creator-image2ppt/projects')
    args = p.parse_args()

    project = Path(args.base) / f"{args.date}_{args.slug}"
    for d in ['original_inputs','component_images','imagegen_assets','diagnostics']:
        (project/d).mkdir(parents=True, exist_ok=True)
    if args.source:
        src = Path(args.source)
        if src.exists():
            shutil.copy2(src, project/'original_inputs'/src.name)
    print(project)

if __name__ == '__main__':
    main()
