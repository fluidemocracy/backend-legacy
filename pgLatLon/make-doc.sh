#!/bin/sh
#
# This command can be used to update the README.html file after changing the
# README.mkd file.

echo "<html><head><title>"`grep '[^ \t\r\n][^ \t\r\n]*' README.mkd | head -n 1`"</title></head><body>" > README.html
markdown2 README.mkd >> README.html
echo "</body></html>" >> README.html
