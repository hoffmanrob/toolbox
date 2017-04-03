#!/usr/bin/env ruby

## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.

## Copyright 2015-2017 Rob Hoffman, with gratitude to CACI Limited for permission to open source.

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
require 'mail'
require 'socket'
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
$error_count = 0
$this_host = Socket.gethostname
$timestamp = Time.new.strftime("%Y.%m.%d-%H.%M")
$backups_dir = "/data/backups"
$log_dir = "/data/logs"
$logfile = "#{$log_dir}/backup_atlassian_database.log"
$mail_body = "#{ENV['HOME']}/.#{File.basename($0, File.extname($0))}_mail_body"
$mail_from = "#{ENV['USER']}@#{$this_host}"
$mail_recipients = ["user@example.com"]
$mail_on_fail = true
$mail_on_success = false
$mail_on_fail_subject = "[SOME ACCOUNT] ALERT: Database Backup Failed"
$mail_on_success_subject = "[SOME ACCOUNT] INFO: Database Backup Succeeded"
$max_age = 30


#########################################
## No edits required beyond this point ##
#########################################


## Method to compose email body.
def add_to_mail(text)
  if $mail_on_fail || $mail_on_success
    begin
      File.open("#{$mail_body}", 'a+', 0660) { |file|
        file.write("#{text}\n")
      }
    rescue => e
      $error_count += 1
      $logger.error("Could not write to #{$mail_body}.")
      $logger.error("#{e.message}")
      exit 1
    end
  end
end


## Method to send email.
def send_mail()
  if $mail_on_success || ($mail_on_fail && $error_count > 0)
    ## Send an email to each mail recipient.
    $mail_recipients.each do |recipient|
      $logger.info("Emailing results to #{recipient}")
      mail = Mail.new do
        from "#{$mail_from}"
        to "#{recipient}"
        if $error_count > 0
          subject "#{$mail_on_fail_subject}"
        else
          subject "#{$mail_on_success_subject}"
        end
        body File.read("#{$mail_body}")
      end
      mail.delivery_method :sendmail
      mail.deliver
    end
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
      $error_count += 1
      $logger.error("There was an error whilst dumping the database.")
      $logger.error("This command failed: '#{cmd}'")
      $logger.error("Is a remote connection allowed from this ip?")
      send_mail
      exit 1
    end
  end
end


## Method to dump postgresql databases.
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
      $error_count += 1
      $logger.error("There was an error whilst dumping the database.")
      $logger.error("This command failed: '#{cmd}'")
      send_mail
      exit 1
    end
  end
end


## Cleanup from previous failed runs.
File.delete($mail_body) if File.exist?($mail_body)


## Set the logging level: DEBUG, INFO, WARN, ERROR, FATAL.
## This will also write to $mail_body.
$logger = Logger.new($logfile, shift_age = 5, shift_size = 512000)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  date_format = datetime.strftime("%Y.%m.%d %H:%M:%S")
  puts "#{severity}: #{msg}\n"
  add_to_mail("#{msg}")
  "[#{date_format}] #{severity}: #{msg}\n"
end


## Usage display.
options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on( "-h", "--help", "Display this screen" ) do
    puts opts
    exit 2
  end

  opts.on( "-a", "--application APP", [:bamboo, :crowd, :crowdid, :jira, :stash, :wiki], \
           "Where APP is one of [bamboo, crowd, crowdid, jira, stash, wiki]" ) do |app|
    options[:app] = app
  end
end


## Make the -a argument mandatory.
begin
  optparse.parse!
  mandatory = [:app]
  missing = mandatory.select{ |param| options[param].nil? }
  unless missing.empty?
    $error_count += 1
    $logger.error("Missing options: #{missing.join(', ')}")
    puts optparse
    send_mail
    exit 1
  end
rescue => e
  $error_count += 1
  $logger.error("#{e.message}")
  puts optparse
  send_mail
  exit 1
end
puts "Logging to #{$logfile}"


## Assign variables for the requested database.
$app = options[:app]
$db_type = $databases["#{$app}"]["db_type"]
$db_host = $databases["#{$app}"]["db_host"]
$db_port = $databases["#{$app}"]["db_port"]
$db_name = $databases["#{$app}"]["db_name"]
$db_user = $databases["#{$app}"]["db_user"]
$db_password = $databases["#{$app}"]["db_password"]
$dump_file = "#{$backups_dir}/db-dump-#{$app}-#{$timestamp}.sql"
$logger.info("Dumping #{$app} database to #{$dump_file}")


## Write mysql passwords to a file so we don't have to pass it on the command line.
if $db_type == "mysql"
  $password_file = "#{ENV['HOME']}/.my.#{$app}.cnf"
  begin
    File.open($password_file, 'w', 0660) { |file|
      file.write("[mysqldump]\n")
      file.write("user=#{$db_user}\n")
      file.write("password=#{$db_password}\n")
    }
  rescue Exception => e
    $error_count += 1
    $logger.error("Could not write to #{$password_file}.")
    $logger.error("#{e.message}")
    send_mail
    exit 1
  end
end


## Create the db dump.
case
when $db_type == "mysql"
  dump_mysql_db
when $db_type == "postgres"
  dump_postgres_db
else
  $error_count += 1
  $logger.error("Unknown db_type: #{$db_type}")
  send_mail
  exit 1
end


## Restrict access to the db dump.
begin
  FileUtils.chmod(0660, "#{$dump_file}")
rescue => e
  $error_count += 1
  $logger.error("Could modify permissions on #{$dump_file}.")
  $logger.error("#{e.message}")
  send_mail
  exit 1
end


## Compress the backup.
system("gzip #{$dump_file}")


## Cleanup password file.
if $db_type == "mysql"
  begin
    File.delete($password_file) if File.exist?($password_file)
  rescue => e
    $logger.error("#{e.message}")
    send_mail
  end
end


## Prune old backups.
$logger.info("Pruning backups more than #{$max_age} days old.")
def file_age(name)
  (Time.now - File.ctime(name))/(24*3600)
end
Dir.chdir($backups_dir)
Dir.glob("*.sql.gz").each do |filename|
  begin
    File.delete(filename) if file_age(filename) > $max_age
  rescue => e
    $logger.error("#{e.message}")
    send_mail
  end
end


$logger.info("Completed backup of #{$db_name}.")
send_mail


## Cleanup mail file.
File.delete($mail_body) if File.exist?($mail_body)

