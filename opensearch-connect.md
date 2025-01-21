# Password requires a minimum of 8 characters and must contain at least one uppercase letter, one lowercase letter, one digit, and one special character. Password strength can be tested here: https://lowe.github.io/tryzxcvbn
 docker run -d -p 9200:9200 -p 9600:9600 -e "discovery.type=single-node" -e "OPENSEARCH_INITIAL_ADMIN_PASSWORD=GhericS2022!" opensearchproject/opensearch:latest


 docker run --name opensearch --rm -d -p 9200:9200 -e http.port=9200 -e discovery.type=single-node -e http.max_content_length=10MB -e http.cors.enabled=true -e http.cors.allow-origin=\* -e http.cors.allow-headers=X-Requested-With,X-Auth-Token,Content-Type,Content-Length,Authorization -e http.cors.allow-credentials=true -e "OPENSEARCH_INITIAL_ADMIN_PASSWORD=GhericS2022!" opensearchproject/opensearch:latest

http://admin:GhericS2022!@host.docker.internal:9200


curl https://localhost:9200 -ku admin:GhericS2022!