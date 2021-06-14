#!/bin/bash

bundle install
bundle exec ruby versioned_plugins.rb --repair --skip-existing --output-path=$WORKSPACE/
