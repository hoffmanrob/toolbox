#!/usr/bin/env ruby

## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.

## Copyright 2015-2016 Rob Hoffman, with gratitude to CACI Limited for permission to open source.

## This script contains passwords and should NOT be world readable.
##
## This script will dump any defined mysql or postgresql database.
##
## If running from a remote location, eg. a backup server, the database should be
## configured to allow the connection:
##
## MySQL should be configured to allow a remote connection from the backup server (ex. 192.168.0.1):
##   GRANT ALL PRIVILEGES ON <db_name>.* TO '<db_user>'@'192.168.0.1' IDENTIFIED BY '<db_password>';
##   FLUSH PRIVILEGES;
##
## Postgres should be configured to allow the remote connection:
##   ===== pg_hba.conf =====
##   TYPE  DATABASE  USER        IP-ADDRESS        IP-MASK           METHOD
##   host  all       all         192.168.0.1       255.255.255.0     md5
##   =======================
##   ===== postgresql.conf =====
##   listen_addresses = '*'
##   ===========================

require 'date'
require 'fileutils'
require 'logger'
require 'open3'
require 'optparse'


$databases = {
  "bamboo" => {
    "db_type" => "postgres",
    "db_host" => "bamboo.example.com",
    "db_port" => "5432",
    "db_name" => "bamboo",
    "db_user" => "bamboouser",
    "db_password" => "redacted"
  },
  "crowd" => {
    "db_type" => "mysql",
    "db_host" => "crowd.example.com",
    "db_port" => "3306",
    "db_name" => "crowd",
    "db_user" => "crowduser",
    "db_password" => "redacted"
  },
  "crowdid" => {
    "db_type" => "mysql",
    "db_host" => "crowd.example.com",
    "db_port" => "3306",
    "db_name" => "crowdid",
    "db_user" => "crowduser",
    "db_password" => "redacted"
  },
  "jira" => {
    "db_type" => "postgres",
    "db_host" => "jira.example.com",
    "db_port" => "5432",
    "db_name" => "jira",
    "db_user" => "jirauser",
    "db_password" => "redacted"
  },
  "stash" => {
    "db_type" => "postgres",
    "db_host" => "stash.example.com",
    "db_port" => "5432",
    "db_name" => "stash",
    "db_user" => "stash",
    "db_password" => "redacted"
  },
  "wiki" => {
    "db_type" => "postgres",
    "db_host" => "wiki.example.com",
    "db_port" => "5432",
    "db_name" => "wiki",
    "db_user" => "wikiuser",
    "db_password" => "redacted"
  }
}
$timestamp = Time.new.strftime("%Y.%m.%d-%H.%M")
$backups_dir = "/data/backups"
$log_dir = "/data/logs"
$logfile = "#{$log_dir}/backup_atlassian_database.log"
$max_age = 30


#########################################
## No edits required beyond this point ##
#########################################

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on( "-h", "--help", "Display this screen" ) do
    puts opts
    exit
  end

  opts.on( "-a", "--application ENV", [:bamboo, :crowd, :crowdid, :jira, :stash, :wiki], \
           "Where ENV is one of [bamboo, crowd, crowdid, jira, stash, wiki]" ) do |env|
    options[:env] = env
  end
end


## Make the -a argument mandatory.
begin
  optparse.parse!
  mandatory = [:env]
  missing = mandatory.select{ |param| options[param].nil? }
  unless missing.empty?
    puts "Missing options: #{missing.join(', ')}"
    puts optparse
    exit
  end
rescue OptionParser::InvalidOption, OptionParser::MissingArgument
  puts $!.to_s
  puts optparse
  exit
end


## Set the logging level: DEBUG, INFO, WARN, ERROR, FATAL.
$logger = Logger.new($logfile, shift_age = 5, shift_size = 1024000)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  date_format = datetime.strftime("%Y.%m.%d %H:%M:%S")
  puts "#{severity}: #{msg}\n"
  "[#{date_format}] #{severity}: #{msg}\n"
end
puts "Logging to #{$logfile}"


## Assign variables for the requested environment.
$app = options[:env]
$db_type = $databases["#{$app}"]["db_type"]
$db_host = $databases["#{$app}"]["db_host"]
$db_port = $databases["#{$app}"]["db_port"]
$db_name = $databases["#{$app}"]["db_name"]
$db_user = $databases["#{$app}"]["db_user"]
$db_password = $databases["#{$app}"]["db_password"]
$dump_file = "#{$backups_dir}/db-dump-#{$app}-#{$timestamp}.sql"


## Restrict access to the log file as errors may contain passwords.
$logger.info("Dumping #{$app} database to #{$dump_file}")
FileUtils.chmod(0660, "#{$logfile}")


## Write mysql passwords to a file so we don't have to pass it on the command line.
if $db_type == "mysql"
  $password_file = "#{$backups_dir}/.my.#{$app}.cnf"
  begin
    File.open($password_file, 'w', 0660) { |file|
      file.write("[mysqldump]\n")
      file.write("user=#{$db_user}\n")
      file.write("password=#{$db_password}\n")
    }
  rescue Exception => e
    $logger.error("Could not write to #{$password_file}.")
    $logger.error("#{e.message}")
    raise
  end
end


## Method to dump mysql databases.
def dump_mysql_db()
  cmd = "/usr/bin/mysqldump --defaults-file=#{$password_file} --default-character-set=utf8 \
         -h #{$db_host} -P #{$db_port} -v #{$db_name} > #{$dump_file}"
  Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
    while line = stdout.gets
      $logger.info line.chomp
    end
    ## Commenting out stderr to reduce log clutter. mysqldump writes stdout to stderr.
    #while line = stderr.gets
    #  $logger.error line.chomp
    #end
    exit_status = wait_thr.value
    unless exit_status.success?
      $logger.error("There was an error whilst dumping the database.")
      $logger.error("This command failed: '#{cmd}'")
      $logger.error("Is a remote connection allowed from this ip?")
      abort
    end
  end
end


## Method to dump postgres databases.
def dump_postgres_db()
  cmd = "/usr/bin/pg_dump -o -U #{$db_user} -h #{$db_host} -p #{$db_port} #{$db_name} > #{$dump_file}"
  cmd_with_password = "export PGPASSWORD=#{$db_password}; #{cmd}"
  Open3.popen3(cmd_with_password) do |stdin, stdout, stderr, wait_thr|
    while line = stdout.gets
      $logger.info line.chomp
    end
    while line = stderr.gets
      $logger.error line.chomp
    end
    exit_status = wait_thr.value
    unless exit_status.success?
      $logger.error("There was an error whilst dumping the database.")
      $logger.error("This command failed: '#{cmd}'")
      $logger.error("Is a remote connection allowed from this ip?")
      abort
    end
  end
end


## Create the db dump.
case
when $db_type == "mysql"
  dump_mysql_db
when $db_type == "postgres"
  dump_postgres_db
else
  $logger.error("Unknown db_type: #{$db_type}")
  abort
end


## Restrict access to the db dump.
begin
  FileUtils.chmod(0660, "#{$dump_file}")
rescue Exception => e
  $logger.error("Could modify permissions on #{$dump_file}.")
  $logger.error("#{e.message}")
  raise
end


## Compress the backup.
system("/bin/gzip #{$dump_file}")


## Remove the password file.
if $db_type == "mysql"
  begin
    File.delete($password_file)
  rescue Exception => e
    $logger.error("Could not delete #{$password_file}.")
    $logger.error("#{e.message}")
    raise
  end
end


## Prune old backups.
$logger.info("Pruning backups more than #{$max_age} days old.")
def file_age(name)
  (Time.now - File.ctime(name))/(24*3600)
end
Dir.chdir($backups_dir)
Dir.glob("*.sql.gz").each { |filename| File.delete(filename) if file_age(filename) > $max_age }


$logger.info("Completed backup of #{$db_name}.")

