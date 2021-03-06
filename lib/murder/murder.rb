# Copyright 2010 Twitter, Inc.
# Copyright 2010 Larry Gadea <lg@twitter.com>
# Copyright 2010 Matt Freels <freels@twitter.com>
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

namespace :murder do
  desc <<-DESC
  Compresses the directory specified by the passed-in argument 'files_path' and creates a .torrent file identified by the 'tag' argument. Be sure to use the same 'tag' value with any following commands. Any .git directories will be skipped. Once completed, the .torrent will be downloaded to your local /tmp/TAG.tgz.torrent.
  DESC
  task :create_torrent, :roles => :seeder do
    require_tag

    if !(seeder_files_path = (default_seeder_files_path if default_seeder_files_path != "") || ENV['files_path'])
      puts "You must specify a 'files_path' parameter with the directory on the seeder which contains the files to distribute"
      exit(1)
    end

    if ENV['path_is_directory']
      run "tar -cz -C #{seeder_files_path}/ -f #{filename} --exclude \".git*\" ."
    elsif compress
      run "if ! [ -e #{filename} ] && [ -e #{seeder_files_path} ]; then tar --checkpoint=10000 --checkpoint-action=echo=\"#%u\" --absolute-names -czf #{filename} #{seeder_files_path}  2>&1; fi"
    else
      run "cp \"#{seeder_files_path}\" #{filename}"
    end

    tracker = find_servers(:roles => :tracker).first
    tracker_host = tracker.host
    tracker_port = '8998'

    run "python #{remote_murder_path}/murder_make_torrent.py '#{filename}' #{tracker_host}:#{tracker_port} '#{filename}.torrent'"

    download_torrent unless ENV['do_not_download_torrent']
  end

  desc <<-DESC
  Although not necessary to run, if the file from create_torrent was lost, you can redownload it from the seeder using this task. You must specify a valid 'tag' argument.
  DESC
  task :download_torrent, :roles => :seeder do
    require_tag
    download("#{filename}.torrent", "#{filename}.torrent", :via => :scp)
  end

  desc <<-DESC
  Will cause the seeder machine to connect to the tracker and start seeding. The ip address returned by the 'host' bash command will be announced to the tracker. The server will not stop seeding until the stop_seeding task is called. You must specify a valid 'tag' argument (which identifies the .torrent in /tmp to use)
  DESC
  task :start_seeding, :roles => :seeder do
    require_tag
    run "screen -dmS 'seeder-#{tag}' python #{remote_murder_path}/murder_client.py seeder '#{filename}.torrent' '#{filename}' $(ip r | grep -o -E 'eth0 .+ src [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | awk '{print $7}')"
  end

  desc <<-DESC
  If the seeder is currently seeding, this will kill the process. Note that if it is not running, you will receive an error. If a peer was downloading from this seed, the peer will find another host to receive any remaining data. You must specify a valid 'tag' argument.
  DESC
  task :stop_seeding, :roles => :seeder do
    require_tag
    run("pid=$(pgrep -f 'SCREEN.+[s]eeder-#{tag}'); sudo kill -9 $pid")
  end

  desc <<-DESC
  Instructs all the peer servers to connect to the tracker and start download and spreading pieces and files amongst themselves. You must specify a valid 'tag' argument. Once the download is complete on a server, that server will fork the download process and seed for 30 seconds while returning control to Capistrano. Cap will then extract the files to the passed in 'destination_path' argument to destination_path/TAG/*. To not create this tag named directory, pass in the 'no_tag_directory=1' argument. If the directory is empty, this command will fail. To clean it, pass in the 'unsafe_please_delete=1' argument. The compressed tgz in /tmp is never removed. When this task completes, all files have been transferred and moved into the requested directory.
  DESC
  task :peer, :roles => :peer do
    require_tag

    if !(destination_path = (default_destination_path if default_destination_path != "") || ENV['destination_path'])
      puts "You must specify a 'destination_path' parameter with the directory in which to place transferred (and extract) files. Note that inside this directory, a new directory named by the tag will be created. It is inside of this second diectory that the files which the torrent was created from will be placed. To not create this second directory, pass in parameter 'no_tag_directory=1'"
      exit(1)
    end

    if !ENV['no_tag_directory'] && ENV['path_is_directory']
      destination_path += "/#{tag}"
    end

    if ENV['path_is_directory']
      run "mkdir -p #{destination_path}/"
    end

    if ENV['unsafe_please_delete']
      run "rm -rf '#{destination_path}/'*"
    end
    if !ENV['no_tag_directory'] && ENV['path_is_directory']
      run "find '#{destination_path}/'* >/dev/null 2>&1 && echo \"destination_path #{destination_path} on $HOSTNAME is not empty\" && exit 1 || exit 0"
    end

    upload("#{filename}.torrent", "#{filename}.torrent", :via => :scp)
    run "python #{remote_murder_path}/murder_client.py peer '#{filename}.torrent' '#{filename}' #{find_servers(:roles => :tracker).first}"

   # hackety hack
   # teardown_connections_to(sessions.keys)
   # # stayin' alive
   # 6.times do
   #   sessions.values.each do |session|
   #     puts "Stayin alive"
   #     session.send_global_request("keep-alive@openssh.com")
   #     sleep 10
   #   end
   # end

    if ENV['path_is_directory']
      run "tar xf #{filename} -C #{destination_path}"
    elsif compress
      # implicitly has the destination_path
      run "tar --checkpoint=100000 --checkpoint-action=echo=\"#%u: %dT\" --absolute-names -xf #{filename} 2>&1"
    else
      run "mv #{filename} #{destination_path}"
    end

    store_destination_md5(destination_path) if generate_md5
  end

  task :stop_peering, :roles => :peer do
    terminate_peering_command = %Q(pid=$(pgrep -f '[m]urder_client.py peer.+#{filename}'); if [ -n "$pid" ]; then sudo kill -9 $pid; fi)

    require_tag

    run terminate_peering_command
  end

  task :clean_temp_files, :roles => [:peer, :seeder] do
    require_tag
    run "rm -f #{filename} #{filename}.torrent || exit 0"
  end

  ###

  def require_tag
    if !(temp_tag = (default_tag if default_tag != "") || ENV['tag'])
      puts "You must specify a 'tag' parameter to identify the transfer"
      exit(1)
    end

    if (temp_tag.include?("/"))
      puts "Tag cannot contain a / character"
      exit(1)
    end

    set(:tag) { temp_tag }
    set(:filename) { compress ? "#{ENV['temp_file_path']}.tgz" : ENV['temp_file_path'] }
  end

  def store_destination_md5(file_path)
    md5_file = "#{file_path}.md5"

    puts "# Generating md5 hash for #{file_path}"
    run("if ! [ -s #{md5_file} ]; then md5sum #{file_path} | awk '{print $1}' | tee #{md5_file}; fi")
    puts "# md5 hash saved"
  end
end
