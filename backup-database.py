#!/usr/bin/env python3

## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.
##
## Copyright 2017 Rob Hoffman


## This script will dump any defined mysql or postgres database. By default, it pulls in its
## configuration from /etc/{MY_ORG}/backup-database.yaml, where MY_ORG is an environment variable
## on the host os. You can override the default by setting CONFIG_FILE below. In principle,
## this should allow you to have a single db backup script that will work on any linux server.
## 
## If running from a remote location, eg. a backup server, the database should be
## configured to allow the connection:
##
## MySQL should be configured to allow the remote connection:
##   GRANT ALL PRIVILEGES ON <db_name>.* TO '<db_user>'@'192.168.148.152' IDENTIFIED BY '<db_password>';
##   FLUSH PRIVILEGES;
##
## Postgres should be configured to allow the remote connection:
##   ===== pg_hba.conf =====
##   TYPE  DATABASE  USER        IP-ADDRESS        IP-MASK           METHOD
##   host  all       all         192.168.0.54      255.255.255.0     md5
##   =======================
##   ===== postgresql.conf =====
##   listen_addresses = '*'
##   ===========================
##
## Non-core dependencies:
##   pyyaml:
##     pip3 install pyyaml
##     sudo apt-get install python-yaml
##     sudo yum install python-yaml

import argparse
import logging
import logging.handlers
import os
import socket
import subprocess
import time
import yaml


## Only set this if you do not want to use the default of /etc/{MY_ORG}/backup-database.yaml.
#CONFIG_FILE = "/path/to/my.yaml"


## Set some defaults.
TIMESTAMP = time.strftime("%Y.%m.%d-%H.%M")


## Usage:
parser = argparse.ArgumentParser()
parser.add_argument("-d", "--database", help="The database to dump, listed in the yaml config.", required=True)
args = parser.parse_args()
database = args.database


def dump_mysql_db(db_dict):
  db_host = db_dict["db_host"]
  db_port = db_dict["db_port"]
  db_name = db_dict["db_name"]
  db_user = db_dict["db_user"]
  db_password = db_dict["db_password"]

  ## Use a defaults-file to prevent the password showing in the process list.
  password_file = os.getenv("HOME") + "/.my." + database + ".cnf"
  file = open(password_file, "w")
  file.write("[mysqldump]\n")
  file.write("user=" + db_user + "\n")
  file.write("password=" + db_password + "\n")
  file.close()
  os.chmod(password_file, 0o660)

  logging.info("Dumping mysql database to " + backup_file)
  cmd = "mysqldump --defaults-file=" + password_file + " -h " + db_host + " -P " + str(db_port) + " -v " + db_name + " > " + backup_file
  process = subprocess.Popen(cmd,
                             shell=True,
                             stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
  stdout, stderr = process.communicate()
  if process.returncode != 0:
    logging.error(stderr)
    raise SystemExit
  

def dump_postresql_db(db_dict):
  db_host = db_dict["db_host"]
  db_port = db_dict["db_port"]
  db_name = db_dict["db_name"]
  db_user = db_dict["db_user"]
  db_password = db_dict["db_password"]

  logging.info("Dumping postresql database to " + backup_file)
  cmd = "export PGPASSWORD=" + db_password + "; pg_dump -o -U " + db_user + " -h " + db_host + " -p " + str(db_port) + " " + db_name + " > " + backup_file
  process = subprocess.Popen(cmd,
                             shell=True,
                             stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
  stdout, stderr = process.communicate()
  if process.returncode != 0:
    logging.error(stderr)
    raise SystemExit


## Add a console logger.
logger = logging.getLogger()
logger.setLevel(logging.INFO)
logConsoleFormatter = logging.Formatter('%(message)s') 
consoleHandler = logging.StreamHandler()
consoleHandler.setFormatter(logConsoleFormatter)
logger.addHandler(consoleHandler)


## Locate the yaml config file.
try:
  ## Test if a CONFIG_FILE override exists.
  CONFIG_FILE
except NameError:
  ## CONFIG_FILE is not defined. Try importing from the default path.
  if os.getenv('MY_ORG') == None:
    logging.error("Neither CONFIG_FILE nor MY_ORG is defined.")
    raise SystemExit
  else:
    CONFIG_FILE = "/etc/" + os.getenv('MY_ORG') + "/backup-database.yaml"


## Import configuration from the yaml file.
logging.info("Importing configuration from " + CONFIG_FILE)
with open(CONFIG_FILE, 'r') as stream:
  try:
    config = yaml.safe_load(stream)
  except yaml.YAMLError as e:
    logging.error(e)


## Add a log file to the logger. This comes after importing the config file so we know what
## directory to log to. Each database gets its own log file.
LOG_FILE = config['log_dir'] + "/backup-database-" + database + ".log"
logging.info("Now logging to " + LOG_FILE)
logFileFormatter = logging.Formatter('%(asctime)s %(levelname)s: %(message)s', datefmt='%m-%d-%Y %H:%M:%S')
fileHandler = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=1048576, backupCount=10)
fileHandler.setFormatter(logFileFormatter)
logger.addHandler(fileHandler)


## Load settings for the specified database.
logging.info("Beginning backup of database " + database)
db_dict = None
for i in config["databases"]:
  for key, value in i.items():
    if key == database:
      db_dict = value

if not db_dict:
  logging.error("Couldn't find configuration for database '" + database + "' in " + CONFIG_FILE)
  raise SystemExit
else:
  logging.info("Loading configuration for database '" + database + "' from " + CONFIG_FILE)


## Specify the backup file.
try:
  backup_dir = db_dict["backup_dir"]
except:
  if not config["backup_dir"]:
    logging.error("backup_dir is not defined in " + CONFIG_FILE)
    raise SystemExit
  else:
    backup_dir = config["backup_dir"]

backup_file = backup_dir + "/db-dump-" + database + "-" + TIMESTAMP + ".sql"


## Dump the database.
if db_dict["db_type"] == "mysql":
  dump_mysql_db(db_dict)
elif db_dict["db_type"] == "postgresql":
  dump_postresql_db(db_dict)
else:
  logging.error("db_type must be either mysql or postgresql.")
  raise SystemExit


## Secure the backup.
os.chmod(backup_file, 0o660)


logging.info("Backup completed.")

