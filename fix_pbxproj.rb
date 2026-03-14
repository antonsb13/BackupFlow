require 'xcodeproj'
project_path = 'BackupFlow.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# First target is BackupFlow
target = project.targets.first

# Find the group
group = project.main_group.find_subpath(File.join('Sources', 'BackupFlow', 'Services'), false)

if group.nil?
  puts "Group not found"
  exit 1
end

# Find the file reference
file_ref = group.files.find { |f| f.path == 'SyncHistoryManager.swift' }

if file_ref.nil?
  puts "File reference not found in group, creating it..."
  file_ref = group.new_file('SyncHistoryManager.swift')
end

# Check if it's in the compile sources phase
sources_phase = target.source_build_phase
existing_build_file = sources_phase.files.find { |bf| bf.file_ref == file_ref }

if existing_build_file
  puts "Already in sources phase."
else
  puts "Adding to sources phase..."
  sources_phase.add_file_reference(file_ref)
  project.save
  puts "Fixed and saved project."
end
