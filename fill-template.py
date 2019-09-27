#!/usr/bin/env python3

from jinja2 import Environment, FileSystemLoader
import yaml
import sys

input = sys.argv[1]
output = sys.argv[2]

config_data = yaml.load(open('./config.yml'), Loader=yaml.FullLoader)
env = Environment(loader=FileSystemLoader('./'))
template = env.get_template(input)

#print(template.render(config_data))
with open(output, 'w') as f:
    f.write(template.render(config_data))
