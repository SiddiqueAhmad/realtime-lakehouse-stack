#!/usr/bin/env python3
"""Run the original 20 black-box cases; substitute only the Compose deployment."""
import importlib.util
import os
from pathlib import Path
HERE=Path(__file__).resolve().parent
BASE=HERE.parent/'delta-policast-sme-demo'

def run():
    os.environ['TABLE_FORMAT']='ducklake'
    spec=importlib.util.spec_from_file_location('original_governance',BASE/'tests/test_governance.py')
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.COMPOSE=['docker','compose','-f',str(HERE/'docker-compose.yml')]
    module.main()
if __name__=='__main__':run()
