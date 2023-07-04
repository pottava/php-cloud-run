FROM php:8.2-fpm

ENV TZ=Asia/Tokyo

ADD conf/php.ini /usr/local/etc/php/

WORKDIR /var/www/html
ADD src /var/www/html
