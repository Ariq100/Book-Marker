require 'xcodeproj'

project_path = 'Book Marker.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.first

# Helper to find or create group
def find_or_create_group(parent, group_name)
  parent.groups.find { |g| g.display_name == group_name || g.name == group_name } || parent.new_group(group_name)
end

main_group = find_or_create_group(project.main_group, 'Book Marker')

files_to_add = [
  { path: 'Book Marker/Services/BookContentService.swift', group: 'Services' },
  { path: 'Book Marker/Services/CoverImageCache.swift', group: 'Services' },
  { path: 'Book Marker/Views/Search/SpotlightSearchOverlay.swift', group: 'Views/Search' }
]

files_to_add.each do |file_info|
  # navigate groups
  current_group = main_group
  file_info[:group].split('/').each do |sub_group_name|
    current_group = find_or_create_group(current_group, sub_group_name)
  end
  
  # check if file already exists in project
  existing_ref = current_group.files.find { |f| f.path == file_info[:path].split('/').last }
  
  unless existing_ref
    file_ref = current_group.new_file(file_info[:path].split('/').last)
    # Add to target
    target.add_file_references([file_ref])
    puts "Added #{file_info[:path]}"
  else
    puts "Already in project: #{file_info[:path]}"
  end
end

project.save
puts "Project saved."
