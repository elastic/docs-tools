#!/bin/bash

bundle install
bundle exec ruby versioned_plugins.rb --repair --test --submit-pr --skip-existing --output-path=$WORKSPACE/
