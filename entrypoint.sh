#!/bin/bash

set -e

port_client_id="$INPUT_PORTCLIENTID"
port_client_secret="$INPUT_PORTCLIENTSECRET"
port_run_id="$INPUT_PORTRUNID"
github_token="$INPUT_TOKEN"
blueprint_identifier="$INPUT_BLUEPRINTIDENTIFIER"
repository_name="$INPUT_REPOSITORYNAME"
org_name="$INPUT_ORGANIZATIONNAME"
cookie_cutter_template="$INPUT_COOKIECUTTERTEMPLATE"
template_directory="$INPUT_TEMPLATEDIRECTORY"
port_user_inputs="$INPUT_PORTUSERINPUTS"
monorepo_url="$INPUT_MONOREPOURL"
scaffold_directory="$INPUT_SCAFFOLDDIRECTORY"
create_port_entity="$INPUT_CREATEPORTENTITY"
private_repo="$INPUT_PRIVATEREPO"
branch_name="port_$port_run_id"
git_url="$INPUT_GITHUBURL"
aws_account="$INPUT_AWSACCOUNT"
role_arn="$INPUT_ROLEARN"

get_access_token() {
  curl -s --location --request POST 'https://api.getport.io/v1/auth/access_token' --header 'Content-Type: application/json' --data-raw "{
    \"clientId\": \"$port_client_id\",
    \"clientSecret\": \"$port_client_secret\"
  }" | jq -r '.accessToken'
}

send_log() {
  message=$1
  curl --location "https://api.getport.io/v1/actions/runs/$port_run_id/logs" \
    --header "Authorization: Bearer $access_token" \
    --header "Content-Type: application/json" \
    --data "{
      \"message\": \"$message\"
    }"
}

add_link() {
  url=$1
  curl --request PATCH --location "https://api.getport.io/v1/actions/runs/$port_run_id" \
    --header "Authorization: Bearer $access_token" \
    --header "Content-Type: application/json" \
    --data "{
      \"link\": \"$url\"
    }"
}

create_repository() {  
  resp=$(curl -H "Authorization: token $github_token" -H "Accept: application/json" -H "Content-Type: application/json" $git_url/users/$org_name)

  userType=$(jq -r '.type' <<< "$resp")
    
  if [ $userType == "User" ]; then
    curl -X POST -i -H "Authorization: token $github_token" -H "X-GitHub-Api-Version: 2022-11-28" \
       -d "{ \
          \"name\": \"$repository_name\", \"private\": $private_repo
        }" \
      $git_url/user/repos
  elif [ $userType == "Organization" ]; then
    curl -i -H "Authorization: token $github_token" \
       -d "{ \
          \"name\": \"$repository_name\", \"private\": $private_repo
        }" \
      $git_url/orgs/$org_name/repos
  else
    echo "Invalid user type"
  fi

  curl -X PUT \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d '{"enabled": true}' \
      $git_url/repos/$org_name/$repository_name/actions/permissions
}

create_repo_secrets() {
  repo_key_response=$(curl -H "Authorization: token $github_token" \
                          -H "Content-Type: application/json" \
                          "$git_url/repos/$org_name/$repository_name/actions/secrets/public-key")

  repo_key=$(echo "$repo_key_response" | jq -r '.key')
  repo_key_id=$(echo "$repo_key_response" | jq -r '.key_id')

  account_secret=$(python /util/encrypt-secret.py $repo_key $aws_account)
  role_secret=$(python /util/encrypt-secret.py $repo_key $role_arn)

  curl -X PUT \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d "{\"encrypted_value\":\"$account_secret\",\"key_id\":\"$repo_key_id\"}" \
      "$git_url/repos/$org_name/$repository_name/actions/secrets/ACCOUNT_ID"

  curl -X PUT \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d "{\"encrypted_value\":\"$role_secret\",\"key_id\":\"$repo_key_id\"}" \
      "$git_url/repos/$org_name/$repository_name/actions/secrets/AWS_ACCESS_ROLE"
}

clone_monorepo() {
  git clone $monorepo_url monorepo
  cd monorepo
  git checkout -b $branch_name
}

prepare_cookiecutter_extra_context() {
  echo "$port_user_inputs" | jq -r 'with_entries(select(.key | startswith("cookiecutter_")) | .key |= sub("cookiecutter_"; ""))'
}

cd_to_scaffold_directory() {
  if [ -n "$monorepo_url" ] && [ -n "$scaffold_directory" ]; then
    cd $scaffold_directory
  fi
}

apply_cookiecutter_template() {
  extra_context=$(prepare_cookiecutter_extra_context)

  echo "🍪 Applying cookiecutter template $cookie_cutter_template with extra context $extra_context"
  # Convert extra context from JSON to arguments
  args=()
  for key in $(echo "$extra_context" | jq -r 'keys[]'); do
      args+=("$key=$(echo "$extra_context" | jq -r ".$key")")
  done

  # Call cookiecutter with extra context arguments

  echo "cookiecutter --no-input $cookie_cutter_template $args"

  # Call cookiecutter with extra context arguments

  if [ -n "$template_directory" ]; then
    cookiecutter --no-input $cookie_cutter_template --directory $template_directory "${args[@]}"
  else
    cookiecutter --no-input $cookie_cutter_template "${args[@]}"
  fi
}


push_to_repository() {
  if [ -n "$monorepo_url" ] && [ -n "$scaffold_directory" ]; then
    git config user.name "GitHub Actions Bot"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add .
    git commit -m "Scaffolded project in $scaffold_directory"
    git push -u origin $branch_name

    send_log "Creating pull request to merge $branch_name into main 🚢"

    owner=$(echo "$monorepo_url" | awk -F'/' '{print $4}')
    repo=$(echo "$monorepo_url" | awk -F'/' '{print $5}')

    echo "Owner: $owner"
    echo "Repo: $repo"

    PR_PAYLOAD=$(jq -n --arg title "Scaffolded project in $repo" --arg head "$branch_name" --arg base "main" '{
      "title": $title,
      "head": $head,
      "base": $base
    }')

    echo "PR Payload: $PR_PAYLOAD"

    pr_url=$(curl -X POST \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d "$PR_PAYLOAD" \
      "$git_url/repos/$owner/$repo/pulls" | jq -r '.html_url')

    send_log "Opened a new PR in $pr_url 🚀"
    add_link "$pr_url"

    else
      cd "$(ls -td -- */ | head -n 1)"
      git init
      git config user.name "GitHub Actions Bot"
      git config user.email "github-actions[bot]@users.noreply.github.com"
      git add .
      git commit -m "Initial commit after scaffolding"
      git branch -M main
      git remote add origin https://oauth2:$github_token@github.com/$org_name/$repository_name.git
      git push -u origin main
      git checkout -b dev
      git push -u origin dev
  fi
}


report_to_port() {
  curl --location "https://api.getport.io/v1/blueprints/$blueprint_identifier/entities?run_id=$port_run_id" \
    --header "Authorization: Bearer $access_token" \
    --header "Content-Type: application/json" \
    --data "{
      \"identifier\": \"$repository_name\",
      \"title\": \"$repository_name\",
      \"properties\": {}
    }"
}

create_environments() {
  curl -X PUT \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d '{"wait_timer":0,"prevent_self_review":false,"reviewers":null,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
      "$git_url/repos/$org_name/$repository_name/environments/Prod"

  curl -X PUT \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d '{"wait_timer":0,"prevent_self_review":false,"reviewers":null,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
      "$git_url/repos/$org_name/$repository_name/environments/Dev"

  curl -X POST \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d '{"name":"main"}' \
      "$git_url/repos/$org_name/$repository_name/environments/Prod/deployment-branch-policies"

  curl -X POST \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d '{"name":"dev"}' \
      "$git_url/repos/$org_name/$repository_name/environments/Dev/deployment-branch-policies"

  curl -X POST \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d '{"name":"ENVIRONMENT","value":"prod"}' \
      "$git_url/repos/$org_name/$repository_name/environments/Prod/variables"

  curl -X POST \
      -H "Authorization: token $github_token" \
      -H "Content-Type: application/json" \
      -d '{"name":"ENVIRONMENT","value":"dev"}' \
      "$git_url/repos/$org_name/$repository_name/environments/Dev/variables"
}

main() {
  access_token=$(get_access_token)

  if [ -z "$monorepo_url" ] || [ -z "$scaffold_directory" ]; then
    send_log "Creating a new repository: $repository_name 🏃"
    create_repository
    send_log "Created a new repository at https://github.com/$org_name/$repository_name 🚀"
  else
    send_log "Using monorepo scaffolding 🏃"
    clone_monorepo
    cd_to_scaffold_directory
    send_log "Cloned monorepo and created branch $branch_name 🚀"
  fi

  send_log "Creating repository secrets 🤫"
  create_repo_secrets

  send_log "Starting templating with cookiecutter 🍪"
  apply_cookiecutter_template
  send_log "Pushing the template into the repository ⬆️"
  push_to_repository

  send_log "Creating environments and environment variables 🔀"
  create_environments

  url="https://github.com/$org_name/$repository_name"

  if [[ "$create_port_entity" == "true" ]]
  then
    send_log "Reporting to Port the new entity created 🚢"
    report_to_port
  else
    send_log "Skipping reporting to Port the new entity created 🚢"
  fi

  if [ -n "$monorepo_url" ] && [ -n "$scaffold_directory" ]; then
    send_log "Finished! 🏁✅"
  else
    send_log "Finished! Visit $url 🏁✅"
  fi
}

main
