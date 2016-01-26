require 'spec_helper'

require 'yaml'

describe Nutkins do
  def file_exists path, content
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


  def make_nutkins project_dir = '.', nutkins_content = nil
    nutkins_yaml = './nutkins.yaml'
    if nutkins_content
      file_exists nutkins_yaml, nutkins_content
    else
      no_file nutkins_yaml
    end
    @project_dir = project_dir
    @nutkins = Nutkins::CloudManager.new project_dir: project_dir
  end

  it 'has a version number' do
    expect(Nutkins::VERSION).not_to be nil
  end

  it 'builds a docker image' do
    img = 'some-image'
    repo = 'kittens'
    tag = repo + '/' + img

    make_nutkins

    img_dir = File.join(@project_dir, img)
    file_exists File.join(img_dir, 'nutkin.yaml'), { "repository" => repo }
    dir_exists img_dir
    expect_docker "build", "-t", tag, img_dir

    @nutkins.build 'some-image'
  end
end
