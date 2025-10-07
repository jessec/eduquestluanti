#!/bin/sh


cp -avr ../eduquest/* /home/jesse/eduquestluanti/

cd /home/jesse/eduquestluanti/

git add . ; git commit -m "cc" ; git push origin main -f

cd -

