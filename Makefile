# If it does not exist create it from the template .env file
ENV_FILE=$(shell	echo .env)

ifeq ($(shell uname -s),Darwin)
	SED_DASH_I=sed -i ''
else  # GNU/Linux
	SED_DASH_I=sed -i
endif

#include make.env
include $(ENV_FILE)

# The site to operate on when using drush -l $(SITE) commands
SITE?=default

# Make sure all docker-compose commands use the given project
# name by setting the appropriate environment variables.
export

# MODIFIED BY BD
#default: setup-certs pull drupal/web
default: pull web

.PHONY: pull
pull: docker-compose.yml
ifeq ($(SERVER_TYPE), local)
	# Only need to pull external services if using local images.
#	$(MAKE) vpn-down
	docker-compose pull $(filter $(EXTERNAL_SERVICES), $(SERVICES))
#	$(MAKE) vpn-up
else
	docker-compose pull
endif

# Updates drupal folder to be owned by the host user and nginx group.
.PHONY: set-codebase-owner
.SILENT: set-codebase-owner
set-codebase-owner:
	sudo chown -R $(shell id -u):101 web
	sudo chown -R $(shell id -u):101 vendor
	sudo chown -R $(shell id -u):101 scripts
	sudo chown -R $(shell id -u):101 config
	sudo chown -R $(shell id -u):101 drush


# Updates settings.php according to the environment variables.
.PHONY: update-settings-php
.SILENT: update-settings-php
update-settings-php:
	$(MAKE) set_basic_perms
	-cp ${DATA_STORAGE}/drupal/settings.php web/sites/default/settings.php
	# if [ ! -f web/sites/default/settings.php ]; then \
	# 	cp web/sites/default/default.settings.php web/sites/default/settings.php; \
	# fi
	$(MAKE) fix-database-settings-php

.PHONY: fix-database-settings-php
fix-database-settings-php:
	$(SED_DASH_I) "s/'password' => '.*'/'password' => '`echo $(MYSQL_ROOT_PASSWORD)`'/g" web/sites/default/settings.php

# Enables twig debugging, disables caching, enables devel/php, etc, by creating symlinks to development.services.yml and settings.local.php
.PHONY: enable-development-services
enable-development-services:
ifeq ($(wildcard $(CURDIR)/web/sites/development.services.yml),)
# development.services.yml already exists. Check that it has twig debugging enabled. If not, then replace the current copy with the debug-enabled version.
	if ! grep -q 'twig.config:' $(CURDIR)/web/sites/development.services.yml; then cp ${DATA_STORAGE}/drupal/development.services.yml web/sites/development.services.yml; fi
else
# development.services.yml doesn't exist. Just create it by copying from data_storage.
	-cp ${DATA_STORAGE}/drupal/development.services.yml web/sites/development.services.yml
endif
ifeq ($(wildcard $(CURDIR)/web/sites/default/settings.local.php),)
	-cp ${DATA_STORAGE}/drupal/settings.local.php web/sites/default/settings.local.php
endif
	if ! grep -q '# For local development, enable settings.local.php' $(CURDIR)/web/sites/default/settings.php; then echo '# For local development, enable settings.local.php\nif (file_exists($$app_root . "/" . $$site_path . "/settings.local.php")) {\n    include $$app_root . "/" . $$site_path . "/settings.local.php";\n}' >> $(CURDIR)/web/sites/default/settings.php; fi

# Exports the sites configuration.
.PHONY: config-export
.SILENT: config-export
config-export:
	$(MAKE) fix_config_perms
	docker-compose exec -T php bash -lc "rm -Rf /var/www/html/config/sync/*"
	docker-compose exec -T php drush config:export -y
	echo "Get newly created files that need to be added to the update script."
	git ls-files -o --exclude-standard --full-name
	echo "Get list of deleted files that need to be added to the update script."
	git ls-files --deleted

.PHONY: bam-backup
bam-backup:
	docker-compose exec -T php bash -lc "chmod 777 /var/www/html/private/backup_migrate"
	-docker-compose exec -T php bash -lc "drush eval 'backup_migrate_perform_backup(\"default_db\", \"private_files\", []);'"

# Import the sites configuration.
# N.B You may need to run this multiple times in succession due to errors in the configurations dependencies.
.PHONY: config-import
.SILENT: config-import
config-import:
	$(MAKE) fix_config_perms
	docker-compose exec -T php bash -lc " drush -l $(SITE) config:import -y"
	$(MAKE) config-cleanup bam-backup

.PHONY: config-cleanup
.SILENT: config-cleanup
config-cleanup:
	# nothing known to do in Archi yet! this is where we'd fix the IIIF URL, for example

.PHONY: databases
databases:
	-docker-compose exec -T db bash -lc "mysql -u root -p${MYSQL_ROOT_PASSWORD} -e 'create database drupal9'"

# Dump database.
database-dump:
ifndef DEST
	$(error DEST is not set)
endif
ifeq ($(wildcard $(CURDIR)/drupal),)
	$(error drupal folder does not exists)
endif
	$(MAKE) bam-backup
	# copy the latest backup to $(DEST)
	cp $$(ls -1t drupal/private/backup_migrate/*.gz | head -1) $(DEST)/dump.sql.gz

# Import database.
database-import: $(SRC)
ifndef SRC
	$(error SRC is not set)
endif
ifeq ($(wildcard $(CURDIR)/drupal),)
	$(error drupal folder does not exists)
endif
	$(MAKE) update-settings-php
	docker cp $(SRC) $$(docker-compose ps -q php):/tmp/dump.sql
	# Need to specify the root user to import the database otherwise it will fail due to permissions.
	docker-compose exec -T php bash -lc '`drush -l $(SITE) sql:connect --extra="-u root --password=$${MYSQL_ROOT_PASSWORD}"` < /tmp/dump.sql'

drupal-public-files-dump:
ifndef DEST
	$(error DEST is not set)
endif
	docker-compose exec -T php bash -lc 'tar zcvf /tmp/public-files.tgz /var/www/html/web/sites/default/files'
	docker cp $$(docker-compose ps -q php):/tmp/public-files.tgz $(DEST)

drupal-public-files-import: $(SRC)
ifndef SRC
	$(error SRC is not set)
endif
	docker cp $(SRC) $$(docker-compose ps -q php):/tmp/public-files.tgz
	docker-compose exec -T php bash -lc 'tar zxvf /tmp/public-files.tgz -C /var/www/html/web/sites/default/files && chown -R nginx:nginx /var/www/html/web/sites/default/files && rm /tmp/public-files.tgz'

reindex-solr:
	docker-compose exec -T php bash -lc 'drush search-api-reindex'
	docker-compose exec -T php bash -lc 'drush search-api-index'

# Helper function to generate keys
.PHONY: setup-certs
.SILENT: setup-certs
setup-certs:
	sudo mkdir -p ${DATA_STORAGE}/letsencrypt/live/archipelago.traefik.me/
	if [ ! -f ${DATA_STORAGE}/letsencrypt/live/archipelago.traefik.me/fullchain.pem ]; then \
		sudo curl http://traefik.me/fullchain.pem -o ${DATA_STORAGE}/letsencrypt/live/archipelago.traefik.me/fullchain.pem; \
	fi
	if [ ! -f ${DATA_STORAGE}/letsencrypt/live/archipelago.traefik.me/privkey.pem ]; then \
		sudo curl http://traefik.me/privkey.pem -o ${DATA_STORAGE}/letsencrypt/live/archipelago.traefik.me/privkey.pem; \
	fi
	-sudo cp -Rf config_storage/ssl_certs/* ${DATA_STORAGE}/letsencrypt/live/

# Destroys everything beware!
.PHONY: clean
.SILENT: clean
clean:
	echo "About to rm your data subdirs, your docker volumes and your web"
	$(MAKE) confirm
	rm .env
	-docker-compose down -v
	sudo rm -fr ${DATA_STORAGE}/* drupal/vendor
	git checkout -- data_storage

web: up composer_install
	# nothing to do

.PHONY: up
up:
	docker-compose up -d --remove-orphans

.PHONY: fetch_stage
fetch_stage:
	$(MAKE) fetch_remote REMOTE_URL=$$STAGE_URL REMOTE_USER=$${STAGE_USER:-ubuntu}

.PHONY: fetch_prod
fetch_prod:
	$(MAKE) fetch_remote REMOTE_URL=$$PROD_URL REMOTE_USER=$${PROD_USER:-ubuntu}

.PHONY: fetch_remote
fetch_remote: data_dirs default
	echo 'FETCHING FROM: $(REMOTE_URL) with user $(REMOTE_USER)'
	$(MAKE) fix_config_perms
	echo "Attempting to ensure VPN is enabled..."
	$(MAKE) vpn-up
	$(MAKE) vpn_check
	#try to run a bam backup. ok if it fails, but it will just fetch you the previous one in that case
	-ssh $(REMOTE_USER)@$(REMOTE_URL) "cd $(REMOTE_PROJ_ROOT) && make bam-backup"
	ssh $(REMOTE_USER)@$(REMOTE_URL) 'sudo chgrp -R $(REMOTE_USER) $(REMOTE_PROJ_ROOT)/drupal/private && mkdir -p $(REMOTE_PROJ_ROOT)/drupal/private/latest && sudo chmod 775 $(REMOTE_PROJ_ROOT)/drupal/private/latest && rm -rf $(REMOTE_PROJ_ROOT)/drupal/private/latest/*'
	ssh $(REMOTE_USER)@$(REMOTE_URL) 'ls -1t $(REMOTE_PROJ_ROOT)/drupal/private/backup_migrate/*.gz | head -1'
	ssh $(REMOTE_USER)@$(REMOTE_URL) 'cp $$(ls -1t $(REMOTE_PROJ_ROOT)/drupal/private/backup_migrate/*.gz | head -1) $(REMOTE_PROJ_ROOT)/drupal/private/latest/'
	ssh $(REMOTE_USER)@$(REMOTE_URL) 'sudo chmod -R 777 $(REMOTE_PROJ_ROOT)/drupal/private/latest'
	-rsync -rhz --no-p --progress --exclude 'backup_migrate' -u $(REMOTE_USER)@$(REMOTE_URL):$(REMOTE_PROJ_ROOT)/drupal/private/ drupal/private && exit
	-rsync -rhz --no-p --progress -u $(REMOTE_USER)@$(REMOTE_URL):$(REMOTE_PROJ_ROOT)/web/sites/default/files/ web/sites/default/files && exit
	sudo rm web/sites/default/settings.php
	rsync -rhz --no-p --progress -u $(REMOTE_USER)@$(REMOTE_URL):$(REMOTE_PROJ_ROOT)/web/sites/default/settings.php web/sites/default/settings.php && exit
	$(MAKE) fix-database-settings-php databases
	sudo chown -R `id -u`:82 drupal/private
	sudo chown -R `id -u`:82 web/sites/default/files
	rm -f ${DATA_STORAGE}/latest_database.sql.gz && cp $$(ls -1t drupal/private/latest/*.gz | head -1) ${DATA_STORAGE}/latest_database.sql.gz
	gunzip -f ${DATA_STORAGE}/latest_database.sql.gz
	# first step: setup script
	$(MAKE) vpn-down
	docker-compose exec php bash -lc  'scripts/archipelago/setup.sh'
	# #import db
	$(MAKE) database-import SRC="${DATA_STORAGE}/latest_database.sql"
	# and prep for reindex
	docker-compose stop solr; $(MAKE) data_dirs; docker-compose start solr
	# sass stalls when on vpn, so shut vpn down first.
	$(MAKE) vpn-down
	$(MAKE) sass minio-init
	# Setting IIIF server
	docker exec -ti esmero-php bash -c "drush -y config-set format_strawberryfield.iiif_settings pub_server_url https://${ARCHIPELAGO_DOMAIN}/cantaloupe/iiif/2"
	# Since fetch_remote is only ever run from a local, we can enable local development settings (twig debugging, disable cache, etc).
	$(MAKE) enable-development-services
	$(MAKE) enable_bd_git_remotes
	docker-compose exec -T php bash -lc "drush updb -y"
	docker-compose exec -T php bash -lc "drush search-api-reindex"
	docker-compose exec -T php bash -lc "drush cron"
	docker-compose exec -T php bash -lc "drush cr -y"
	mkdir -p ${DATA_STORAGE}/drupal && rm -rf ${DATA_STORAGE}/drupal/settings.php
	cp web/sites/default/settings.php ${DATA_STORAGE}/drupal/settings.php

# standalone use: source make.env && make fetch_remote_fedora REMOTE_URL=$PROD_URL

.PHONY: vpn_check
vpn_check:
	@ping -c1 -W1 archi-staging.born-digital.com && echo 'VPN IS CONNECTED!' && exit || echo -n "Now we need to use RSYNC to get some files. Are you on the VPN? [y/N] " && read ans && [ $${ans:-N} = y ]

.PHONY: down
down:
	docker-compose down --remove-orphans

.PHONY: watch
watch:
	# Kill it (if it's already running)
	-docker ps -q --filter "name=gulp" | grep -q . && docker stop gulp && docker rm -fv gulp
	# Pull it
	docker pull registry.gitlab.com/born-digital-public/gulp-sass/gulp-archipelago:latest
	# Start it
	docker run --name gulp --expose=3000-3999 -d -it --mount type=bind,source="$(shell pwd)",target=/app registry.gitlab.com/born-digital-public/gulp-sass/gulp-archipelago:latest
	# Fix it
	docker exec -u root -t -i gulp bash -lc "./permissions.sh"
	# Run it
	docker exec -it gulp bash -lc "./watch.sh"
	#  Clean up after yourself (bet you thought I was going to call it Clean it!)
	-docker-compose exec -T web bash -lc "chown -R `id -u`:`id -g` web/themes"
	-docker ps -q --filter "name=gulp" | grep -q . && docker stop gulp && docker rm -fv gulp

.PHONY: sass
sass:
	# Kill it (if it's already running)
	-docker ps --filter "name=gulp" | grep -q . && docker stop gulp && docker rm -fv gulp
	# Pull it
	docker pull registry.gitlab.com/born-digital-public/gulp-sass/gulp-archipelago:latest
	# Start it
	docker run --name gulp -d -it --mount type=bind,source="$(shell pwd)",target=/app registry.gitlab.com/born-digital-public/gulp-sass/gulp-archipelago:latest
	# Fix it
	docker exec -u root -t -i gulp bash -lc "./permissions.sh"
	# Run it
	docker exec -it gulp bash -lc "./script.sh"
	#  Clean up after yourself (bet you thought I was going to call it Clean it!)
	-docker-compose exec -T  web bash -lc "chown -R `id -u`:`id -g` web/themes"
	-docker ps -q --filter "name=gulp" | grep -q . && docker stop gulp && docker rm -fv gulp

.PHONY: composer_install
composer_install: vpn-down
	docker-compose exec -T php bash -lc "chgrp -R www-data private"
	docker-compose exec -T php bash -lc "chown -R www-data:www-data /var/www/html"
#	-docker-compose exec -T php bash -lc "rm /var/www/html/web/sites/default/default.settings.php"
	docker-compose exec -T -u www-data php bash -lc "COMPOSER_MEMORY_LIMIT=-1 composer install -o --prefer-dist --no-interaction"
	$(MAKE) set_drupal_perms
	$(MAKE) update-settings-php

.PHONY: composer_update
composer_update: vpn-down
	docker-compose exec -T php bash -lc "chown -R www-data:www-data private"
	docker-compose exec -T php bash -lc "chown -R www-data:www-data /var/www/html"
#	-docker-compose exec -T php bash -lc "rm /var/www/html/web/sites/default/default.settings.php"
	# no more --add safe.directory nonsense, please! use `id -u`:www-data perms to make this unnecessary
	docker-compose exec -T -u www-data php bash -lc "COMPOSER_MEMORY_LIMIT=-1 composer update -W -o --prefer-dist --no-interaction"
	$(MAKE) set_drupal_perms
	$(MAKE) update-settings-php

.phony: data_dirs
data_dirs:
ifeq ($(shell uname -s),Darwin)
	sudo mkdir -p ${DATA_STORAGE}/iiifcache/source ${DATA_STORAGE}/db ${DATA_STORAGE}/drupal ${DATA_STORAGE}/iiiftmp ${DATA_STORAGE}/letsencrypt
	sudo rm -rf ${DATA_STORAGE}/solrcore ${DATA_STORAGE}/nginxcache ${DATA_STORAGE}/minio-data
else  # GNU/Linux
	#sudo mkdir -p ${DATA_STORAGE}/private_files/backup_migrate
	sudo mkdir -p ${DATA_STORAGE}/iiifcache/source ${DATA_STORAGE}/db ${DATA_STORAGE}/nginxcache ${DATA_STORAGE}/selfcert ${DATA_STORAGE}/solrcore ${DATA_STORAGE}/drupal ${DATA_STORAGE}/iiiftmp ${DATA_STORAGE}/letsencrypt ${DATA_STORAGE}/miniodata/$(MINIO_BUCKET_MEDIA)
endif
	mkdir -p drupal/private/backup_migrate drupal/private/latest
	$(MAKE) set_basic_perms

.phony: set_basic_perms
set_basic_perms:
	sudo chown `id -u`:`id -g` ${DATA_STORAGE}
	sudo chown -R 999 ${DATA_STORAGE}/db
	# the root group on macs is "wheel" so we can't just say root:root
#	-sudo chown -R root:`sudo id -g` ${DATA_STORAGE}/letsencrypt ${DATA_STORAGE}/miniodata
	-sudo chown -R root:`sudo id -g` ${DATA_STORAGE}/miniodata
#	-sudo chown -R 101:`sudo id -g` ${DATA_STORAGE}/nginxcache
	sudo chown -R 8183:8183 ${DATA_STORAGE}/iiifcache
#	sudo chown -R 8183:8183 ${DATA_STORAGE}/iiiftmp
	-sudo chown -R 8983:8983 ${DATA_STORAGE}/solrcore
	sudo chmod -R 775 ${DATA_STORAGE}
	$(MAKE) set_drupal_perms

.phony: set_drupal_perms
set_drupal_perms:
	-sudo chown -R `id -u`:82 web vendor scripts config drush
	-sudo chmod -R 775 web vendor scripts config drush
	git config core.fileMode false
	# This may not be necessary...
	#-sudo chmod 777 drupal/private drupal/private/latest

.phony: server_hydrate
server_hydrate: data_dirs up
	sudo rm -f /home/gitlab-runner/.bash_logout
	git config --global user.email "patdunlavey@gmail.com"
	git config --global user.name "Pat Dunlavey"
	mkdir -p ${DATA_STORAGE}/drupal && rm -rf ${DATA_STORAGE}/drupal/settings.php
	cp web/sites/default/settings.php ${DATA_STORAGE}/drupal/settings.php
	# Set the IIIF server. This will fail silently if no site; or fix second remote if a db has just been imported
	-docker exec -ti esmero-php bash -c "drush -y config-set format_strawberryfield.iiif_settings pub_server_url https://${ARCHIPELAGO_DOMAIN}/cantaloupe/iiif/2"

.phony: fix_config_perms
.silent: fix_config_perms
fix_config_perms:
	-sudo chown -Rf `id -u`:82 config

# https://github.com/esmero/archipelago-deployment-live/blob/1.0.0-RC3/README.md
.phony: archipelago_init
archipelago_init: data_dirs default
	# SLEEP then do the setup
	sleep 10
	# Running setup script
	docker-compose exec php bash -lc  'scripts/archipelago/setup.sh'
	docker exec -ti esmero-php bash -c "cd web; ../vendor/bin/drush -y si --verbose --existing-config --db-url=mysql://root:${MYSQL_ROOT_PASSWORD}@esmero-db/drupal9 --account-name=admin --account-pass=${DRUPAL_ADMIN_PWD} -r=/var/www/html/web --sites-subdir=default --notify=false; drush cr;"
	docker exec -ti esmero-php bash -c "cd web; chown -R `id -u`:www-data sites;"
	$(MAKE) minio-init
	docker exec -ti esmero-php bash -c 'drush ucrt demo --password="demo"; drush urol metadata_pro "demo"'
	docker exec -ti esmero-php bash -c 'drush ucrt jsonapi --password="jsonapi"; drush urol metadata_api "jsonapi"'
	docker exec -ti esmero-php bash -c 'drush urol administrator "admin"'
	# Manually updated the deploy script to account for domain and SSL issues
	# Running deploy script
	$(MAKE) metadatadisplays-import
	$(MAKE) config-import
	docker exec -ti esmero-php bash -c 'scripts/bd_base/deploy.sh'
	# Setting IIIF server
	docker exec -ti esmero-php bash -c "drush -y config-set format_strawberryfield.iiif_settings pub_server_url https://${ARCHIPELAGO_DOMAIN}/cantaloupe/iiif/2"
	mkdir -p ${DATA_STORAGE}/drupal && rm -rf ${DATA_STORAGE}/drupal/settings.php
	cp web/sites/default/settings.php ${DATA_STORAGE}/drupal/settings.php
	$(MAKE) login git-cleanup
	# You should now have a fully working site with a demonstration AMI set ready to import sample data!
	# To complete demo content setup, process the "Demo Set" AMI set, then add some items to the Home page entity queue.

.PHONY: git-cleanup
.SILENT: git-cleanup
git-cleanup:
	git checkout -- data_storage/nginxcache/.keep

.PHONY: login
.SILENT: login
login:
	echo "\n\n=========== LOGIN ==========="
	docker exec -ti esmero-php bash -c "drush uli --uri=$(ARCHIPELAGO_DOMAIN)"
	echo "=============================\n"

# as long as MINIO_COMMAND_PREFIX is not set (which would point at aws), create a bucket with the creds provided on a local minio instance
.phony: minio-init
minio-init:
ifndef MINIO_COMMAND_PREFIX
	echo "must be a local!"
	rm -rf .aws && mkdir .aws
	echo "[default]\naws_access_key_id=${MINIO_ACCESS_KEY}\naws_secret_access_key=${MINIO_SECRET_KEY}" > .aws/credentials
	-docker run --network="$(shell basename $(CURDIR))_esmero-net" --rm -it -v ${PWD}/.aws/:/root/.aws amazon/aws-cli:latest --endpoint-url http://minio:9000 s3 mb s3://${MINIO_BUCKET_MEDIA}/${MINIO_FOLDER_PREFIX_MEDIA}
#	sudo chown -R `id -u`:82 ${DATA_STORAGE}/miniodata/${MINIO_BUCKET_MEDIA}
	docker exec -ti esmero-php bash -c 'drush cset -y s3fs.settings bucket esmero'
	docker exec -ti esmero-php bash -c 'drush cset -y s3fs.settings use_customhost true'
endif

.phony: fetch_staging_assets
fetch_staging_assets:
# Ensure aws-cli is installed
ifeq (, $(shell which aws))
	$(error The aws command line tool must be installed in the local environment. Cannot fetch assets. See https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
endif
# Ensure MINIO_STAGING environment variables are set.
ifndef MINIO_STAGING_ACCESS_KEY
	$(error Cannot fetch staging assets without having MINIO_STAGING environment variables defined in the local make.env file. These may be copied from the .env file on the staging server.)
endif
# Proceed with minio-init and s3 rsync
	$(MAKE) minio-init
	$(MAKE) ensure_local_aws_staging_credentials
	sudo chown -R `id -u`:82 ${DATA_STORAGE}/miniodata/${MINIO_BUCKET_MEDIA}
	-aws s3 sync --profile=bd-archi-staging s3://${MINIO_STAGING_BUCKET_MEDIA} ${DATA_STORAGE}/miniodata/${MINIO_BUCKET_MEDIA}


.phony: ensure_local_aws_staging_credentials
ensure_local_aws_staging_credentials:
ifneq ($(wildcard $(CURDIR)/.aws/credentials),)
	echo "Credentials file exists. Appending bd-archi-staging profile if not present."
	if ! grep -q '\[bd-archi-staging\]' $(CURDIR)/.aws/credentials; then echo "\n[bd-archi-staging]\naws_access_key_id=${MINIO_STAGING_ACCESS_KEY}\naws_secret_access_key=${MINIO_STAGING_SECRET_KEY}" >> $(CURDIR)/.aws/credentials; fi
else
	echo "Creating aws credentials file."
	echo "\n[bd-archi-staging]\naws_access_key_id=${MINIO_STAGING_ACCESS_KEY}\naws_secret_access_key=${MINIO_STAGING_SECRETE_KEY}" > $(CURDIR)/.aws/credentials
endif

.phony: fetch_prod_assets
fetch_prod_assets:
# Ensure aws-cli is installed
ifeq (, $(shell which aws))
	$(error The aws command line tool must be installed in the local environment. Cannot fetch assets. See https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
endif
# Ensure MINIO_STAGING environment variables are set.
ifndef MINIO_PROD_ACCESS_KEY
	$(error Cannot fetch staging assets without having MINIO_PROD environment variables defined in the local make.env file. These may be copied from the .env file on the staging server.)
endif
# Proceed with minio-init and s3 rsync
	$(MAKE) minio-init
	$(MAKE) ensure_local_aws_prod_credentials
	sudo chown -R `id -u`:82 ${DATA_STORAGE}/miniodata/${MINIO_BUCKET_MEDIA}
	-aws s3 sync --profile=bd-archi-prod s3://${MINIO_PROD_BUCKET_MEDIA} ${DATA_STORAGE}/miniodata/${MINIO_BUCKET_MEDIA}

.phony: ensure_local_aws_prod_credentials
ensure_local_aws_prod_credentials:
ifneq ($(wildcard $(CURDIR)/.aws/credentials),)
	echo "Credentials file exists. Appending bd-archi-prod profile if not present."
	if ! grep -q '\[bd-archi-prod\]' $(CURDIR)/.aws/credentials; then echo "\n[bd-archi-prod]\naws_access_key_id=${MINIO_PROD_ACCESS_KEY}\naws_secret_access_key=${MINIO_PROD_SECRET_KEY}" >> $(CURDIR)/.aws/credentials; fi
else
	echo "Creating aws credentials file."
	echo "\n[bd-archi-prod]\naws_access_key_id=${MINIO_PROD_ACCESS_KEY}\naws_secret_access_key=${MINIO_PROD_SECRETE_KEY}" > $(CURDIR)/.aws/credentials
endif

.phony: samples
samples:
	# TODO - create an archi samples

.phony: start_behat
.silent: start_behat
start_behat:
	docker-compose exec -T php bash -lc "apk update && apk add chromium"
	docker-compose exec -T php bash -lc "pgrep chromium || (chromium-browser --disable-gpu --headless --remote-debugging-address=0.0.0.0 --remote-debugging-port=9222 --no-sandbox --disable-software-rasterizer --disable-dev-shm-usage /dev/null 2>&1 &)"
	mkdir -p codebase/features/screenshots

.phony: stop_behat
stop_behat:
	docker-compose exec -T php bash -lc 'pkill -f "(chrome)?(--headless)"'

.phony: behat_logs
behat_logs:
	#TODO: https://www.chromium.org/for-testers/enable-logging/

.phony: fix_behat_domain
fix_behat_domain:
	docker-compose exec -T -w /var/www/html php bash -c "sed -i 's/archipelago.traefik.me/${ARCHIPELAGO_DOMAIN}/g' behat.yml"

# e.g.  make run_behat ARGS=features/test.feature
.phony: run_behat
run_behat: start_behat fix_behat_domain
	docker-compose exec -T php bash -lc "vendor/bin/behat --colors $(ARGS)"

.phony: clean_behat_debug
clean_behat_debug:
	docker-compose exec -T php bash -lc "rm -rf features/debug/*.html features/debug/*.png features/screenshots/*.jpg"

.phony: behat_help
behat_help:
	docker-compose exec php bash -lc "vendor/bin/behat -di"

.phony: server_clean
server_clean:
	echo "**DANGER** About to rm your SERVER data subdirs, your docker volumes and your web"
	$(MAKE) confirm
	-docker-compose down -v
	mkdir -p data_backup
	# making a backup of site files
	sudo rm -rf data_backup/*
	-sudo mv drupal/private data_backup/
	-sudo mv web/sites/default/files data_backup/
	sudo rm -fr ${DATA_STORAGE}/* drupal/vendor web
	git checkout -- data_storage
	git checkout -- drupal

.phony: confirm
confirm:
	@echo -n "Your DATA_STORAGE location is ${DATA_STORAGE}. Are you sure you want to continue? [y/N] " && read ans && [ $${ans:-N} = y ]

.phony: vpn-down
vpn-down:
	echo "Disabling VPN if enabled to permit composer install to run"
	-if (command -v nmcli &> /dev/null); then nmcli con down id $(BD_VPN_ID) && echo 'VPN is disabled!'; fi

.phony: vpn-up
vpn-up:
	-if (command -v nmcli &> /dev/null); then ping -c1 -W1 archi-staging.born-digital.com && echo 'VPN IS CONNECTED!' && exit || nmcli con up id $(BD_VPN_ID) && echo 'VPN is enabled!'; fi

.phony: enable_bd_git_remotes
enable_bd_git_remotes:
ifeq ($(wildcard $(CURDIR)/web/themes/custom/bd_archipelago_subtheme/.git),)
	cd $(CURDIR)/web/themes/custom; sudo chown `id -u`:82 -R . ; rm -rf bd_archipelago_subtheme; git clone git@gitlab.com:born-digital-us/bd-archi/bd_archipelago_subtheme.git
endif
ifeq ($(wildcard $(CURDIR)/web/modules/bd/bd-base-archi-modules/.git),)
	cd $(CURDIR)/web/modules/bd; sudo chown `id -u`:82 -R . ; rm -rf bd-base-archi-modules; git clone git@gitlab.com:born-digital-us/bd-archi/bd-base-archi-modules.git
endif

.phony: metadatadisplays-io-prepare
metadatadisplays-io-prepare:
	# Tests to see if we have an entry in the /etc/hosts file for the current archipelago domain.
	# If not, we add it.
ifeq (, getent hosts ${ARCHIPELAGO_DOMAIN})
	echo "creating /etc/hosts entry"
	sudo -- sh -c "echo '127.0.0.1       ${ARCHIPELAGO_DOMAIN}' >> /etc/hosts"
endif
	# Tests to see if jq (JSON Processor) is installed. If not, install it. See https://www.baeldung.com/linux/jq-command-json
ifeq (, which jq)
	echo "installing jq"
	sudo apt update && sudo apt install jq
endif

.phony: metadatadisplays-export
metadatadisplays-export: metadatadisplays-io-prepare
    # Use import-export.sh script to export metadatadisplays to code. Save to drupal/config/metadatadisplays
	export JSONAPI_USER="admin"; export JSONAPI_PASSWORD="$(DRUPAL_ADMIN_PWD)"; cd $(ARCHIPELAGO_ROOT)/scripts/archipelago; ./import_export.sh -e -j "$(ARCHIPELAGO_ROOT)/.env" -d "http://$(ARCHIPELAGO_DOMAIN)" -s $(ARCHIPELAGO_ROOT)/config/metadatadisplays

.phony: metadatadisplays-export-use-entity-id
metadatadisplays-export-use-entity-id: metadatadisplays-io-prepare
    # Use import-export.sh script to export metadatadisplays to code. Save to drupal/config/metadatadisplays
	export JSONAPI_USER="admin"; export JSONAPI_PASSWORD="$(DRUPAL_ADMIN_PWD)"; cd $(ARCHIPELAGO_ROOT)/scripts/archipelago; ./import_export.sh -c -e -j "$(ARCHIPELAGO_ROOT)/.env" -d "http://$(ARCHIPELAGO_DOMAIN)" -s $(ARCHIPELAGO_ROOT)/config/metadatadisplays

.phony: metadatadisplays-import
metadatadisplays-import: metadatadisplays-io-prepare
    # This has to run on one line to pass the needed environment variables into the script.
	export JSONAPI_USER="admin"; export JSONAPI_PASSWORD="$(DRUPAL_ADMIN_PWD)"; cd $(ARCHIPELAGO_ROOT)/drupal/scripts/archipelago; ./import_export.sh -i -j "$(ARCHIPELAGO_ROOT)/.env" -d "https://$(ARCHIPELAGO_DOMAIN)" -s $(ARCHIPELAGO_ROOT)/config/metadatadisplays

.PHONY: xdebug
xdebug:
# ifeq (, docker-compose exec -T php bash -lc "which xdebug")
	docker cp config_storage/xdebug/xdebug.ini $$(docker-compose ps -q php):/usr/local/etc/php/conf.d/00_xdebug.ini
	# The following xdebug installation command is adapted from Archipelago's Dockerfile.dev.
	# https://github.com/esmero/archipelago-docker-images/blob/1.1.0/esmero-php-fpm/Dockerfile.dev
	$(MAKE) vpn-down
	-docker-compose exec -T php bash -lc "apk add --no-cache --virtual .build-deps autoconf g++ make; pecl install xdebug; apk del --no-cache .build-deps"
	docker-compose restart php
	docker-compose exec -T php bash -lc "php -i | grep xdebug"
# endif

# TODO: This is not working yet.
.PHONY: xhprof
xhprof:
	docker cp config_storage/xdebug/xhprof.ini $$(docker-compose ps -q php):/usr/local/etc/php/conf.d/01_xhprof.ini
	-docker-compose exec -T php with-contenv bash -lc "pecl install xhprof"
	docker-compose restart php
	docker-compose exec -T php with-contenv bash -lc "php -i | grep xhprof"

.PHONY: enable-cantaloupe-api
enable-cantaloupe-api:
	$(SED_DASH_I) -e '/^endpoint.api.secret =[^ ]*$$/ s/$$/ $(MINIO_SECRET_KEY)/' config_storage/iiifconfig/cantaloupe.properties
