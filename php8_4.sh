SITE='os2display-test.ballerup.dk'

if a2dismod php8.3 && a2enmod php8.4 && apache2ctl configtest; then
    if systemctl restart apache2; then
        echo 'OK: Apache er startet med PHP 8.4.'

        echo
        echo '=== Aktivt modul ==='
        ls -l /etc/apache2/mods-enabled/php*.load

        echo
        echo '=== Lokal backend-test ==='
        LOCAL_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
            -H "Host: $SITE" \
            http://127.0.0.1/client/config.json 2>/dev/null)"

        echo "HTTP $LOCAL_STATUS"

        if [ "$LOCAL_STATUS" = '200' ]; then
            echo 'OK: Backend virker med PHP 8.4.'

            echo
            echo '=== Offentlig test ==='
            curl -k -sS -o /dev/null -w 'HTTP %{http_code}\n' \
                "https://$SITE/client/config.json"
        else
            echo 'FEJL: Lokal backend virker ikke korrekt med PHP 8.4.'
            echo 'Ruller tilbage til PHP 8.3.'

            if a2dismod php8.4 && a2enmod php8.3 && apache2ctl configtest; then
                systemctl restart apache2
                echo 'OK: Apache er rullet tilbage til PHP 8.3.'
            else
                echo 'FEJL: Rollback-konfigurationen fejlede.'
            fi
        fi
    else
        echo 'FEJL: Apache kunne ikke starte med PHP 8.4.'
        echo 'Ruller tilbage til PHP 8.3.'

        if a2dismod php8.4 && a2enmod php8.3 && apache2ctl configtest; then
            systemctl restart apache2
            echo 'OK: Apache er rullet tilbage til PHP 8.3.'
        else
            echo 'FEJL: Rollback-konfigurationen fejlede.'
        fi
    fi
else
    echo 'FEJL: Kunne ikke aktivere PHP 8.4 med gyldig Apache-konfiguration.'
fi
