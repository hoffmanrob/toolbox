#!/bin/env ruby

## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.

## Copyright 2015-2016 Rob Hoffman, with gratitude to CACI Limited for permission to open source.

## This script contains passwords and should NOT be world readable. Use at your own risk.
##
## This script is intended to dump a single application's database for any environment (eg. dev,
## test, stage, prod). Useful for consistent backups during automated deploys.
##
## The sections to create the log and backup directories are commented out because I would
## expect, in most cases, that these would have been created by ansible or the like.

require 'date'
require 'fileutils'
require 'logger'
require 'open3'
require 'optparse'


$backups_dir = "/data/backups"
$db_user = "someuser"
$log_dir = "/data/logs"
$logfile = "#{$log_dir}/mysql-app-backup.log"
$password_file = "#{$backups_dir}/.my.app.cnf"
$max_age = 90
$mysql_hosts = {
  dev: "192.168.0.1",
  systest: "192.168.0.2",
  stage: "192.168.0.3",
  prod: "192.168.0.4"
}
$mysql_passwords = {
  dev: "redacted",
  systest: "redacted",
  stage: "redacted",
  prod: "redacted"
}
$timestamp = Time.new.strftime("%Y.%m.%d-%H-%M")


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

  opts.on( "-e", "--environment ENV", [:dev, :systest, :stage, :prod], \
           "Where ENV is one of [dev, systest, stage, prod]" ) do |env|
    options[:env] = env
  end
end

## Make the -e argument mandatory.
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

## Create the log dir if missing.
#begin
#  Dir.mkdir($log_dir) unless File.directory?($log_dir)
#rescue Exception => e  
#  $logger.error("Could not create the directory #{$log_dir}.")
#  $logger.error("#{e.message}")
#  raise
#end

## Make the log file group-writable.
if !File.file?($logfile)
  File.open("#{$logfile}", 'a') {|f| f.write("Initial log entry.") }
  FileUtils.chmod(0660, "#{$logfile}")
end

## Set the logging level: DEBUG, INFO, WARN, ERROR, FATAL.
$logger = Logger.new $logfile
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  date_format = datetime.strftime("%Y-%m-%d %H:%M:%S")
  puts "#{severity}: #{msg}\n"
  "[#{date_format}] #{severity}: #{msg}\n"
end
puts "Logging to #{$logfile}"

## Create the backups dir if missing.
#begin
#  Dir.mkdir($backups_dir) unless File.directory?($backups_dir)
#rescue Exception => e  
#  $logger.error("Could not create the directory #{$backups_dir}.")
#  $logger.error("#{e.message}")
#  raise
#end

## Ensure the backups dir is NOT world readable.
#if File.world_readable?("#{$backups_dir}")
#  begin
#    FileUtils.chmod(2770, "#{$backups_dir}")
#  rescue Exception => e
#    $logger.error("Could not modify permissions on directory #{$backups_dir}.")
#    $logger.error("#{e.message}")
#    raise
#  end
#  begin
#    FileUtils.chown(nil, "some-admin-group", "#{$backups_dir}")
#  rescue Exception => e
#    $logger.error("Could not change ownership of directory #{$backups_dir}.")
#    $logger.error("#{e.message}")
#    raise
#  end
#end

## Use variables for the requested environment.
$db_host = $mysql_hosts[options[:env]]
$db_password = $mysql_passwords[options[:env]]
$dump_file = "#{$backups_dir}/db.dump.#{options[:env]}.#{$db_user}-#{$timestamp}.sql"
$logger.info("Dumping #{options[:env]} database to #{$dump_file}")

## Write the db password to a file so we don't have to pass it on the command line.
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

## Dump the db.
cmd = "/usr/bin/mysqldump --defaults-file=#{$password_file} --default-character-set=utf8 \
       -h #{$db_host} -v #{$db_user} > #{$dump_file}"
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
    abort
  end
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
$logger.info("Compressing the #{$dump_file} file")
system("/bin/gzip #{$dump_file}")

## Remove the password file.
begin
  File.delete($password_file)
rescue Exception => e
  $logger.error("Could not delete #{$password_file}.")
  $logger.error("#{e.message}")
  raise
end

## Prune old backups.
$logger.info("Pruning backups more than #{$max_age} days old.")
def file_age(name)
  (Time.now - File.ctime(name))/(24*3600)
end
Dir.chdir($backups_dir)
Dir.glob("*.sql.gz").each { |filename| File.delete(filename) if file_age(filename) > $max_age }

