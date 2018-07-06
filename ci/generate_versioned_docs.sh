#!/bin/bash

bundle install
bundle exec ruby versioned_plugins.rb --repair --test --skip-existing --output-path=$WORKSPACE/
