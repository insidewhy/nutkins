require 'spec_helper'

require 'yaml'

describe Nutkins do
  def yaml_file_exists path, content
    expect(File).to receive(:exists?).with(path) { true }
    expect(YAML).to receive(:load_file).with(path) { content }
  end

  def no_file path
    expect(File).to receive(:exists?).with(path) { false }
  end

  def dir_exists path
    expect(Dir).to receive(:exists?).with(path) { true }
  end

  def expect_docker *args
    expect(@nutkins).to receive(:run_docker).with(*args) { true }
  end

  def make_nutkins project_dir: '.', nutkins_content: nil
    @project_dir = project_dir
    @img_dir = File.join(@project_dir, @img)

    nutkins_yaml = './nutkins.yaml'
    if nutkins_content
      yaml_file_exists nutkins_yaml, nutkins_content
    else
      no_file nutkins_yaml
    end
    @nutkins = Nutkins::CloudManager.new project_dir: @project_dir
  end

  def expect_image_dir nutkin_yaml = nil
    nutkin_yaml_path = File.join(@img_dir, 'nutkin.yaml')
    if nutkin_yaml
      yaml_file_exists nutkin_yaml_path, nutkin_yaml
    else
      no_file nutkin_yaml_path
    end
    dir_exists @img_dir
  end

  before :each do
    @img = 'some-image'
    @repo = 'kittens'
    @tag = @repo + '/' + @img
  end

  it 'has a version number' do
    expect(Nutkins::VERSION).not_to be nil
  end

  it 'builds a docker image in a subdirectory' do
    make_nutkins
    expect_image_dir({ "repository" => @repo })
    expect_docker "build", "-t", @tag, @img_dir
    @nutkins.build 'some-image'
  end

  it 'builds a docker image in the project root' do
    make_nutkins
    @img_dir = @project_dir
    expect_image_dir({ "repository" => @repo, "image" => @img })
    expect_docker "build", "-t", @tag, @img_dir
    @nutkins.build
  end
end
