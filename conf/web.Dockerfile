FROM nginx:1.25-alpine

CMD ["/usr/sbin/nginx", "-g", "daemon off;"]

ADD conf/nginx.conf /etc/nginx/
RUN sed -ie 's/app/localhost/g' /etc/nginx/nginx.conf

ADD src /var/www/html
