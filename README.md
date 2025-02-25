# skiFFS_dataconnector
skiFFS_dataconnector


le skiFFS_dataconnector est une extension permetant d'heberger un serveur TCP utilisé pour l'envoie de donnees vers le logiciel "NordicCG" de foxx production.

il est composé d'un script LUA, ouvert pas skiFFS et permettant de recuperer les donnees (starlist + resultats) depuis les notification de skiFFS. C'est donnees sont ecrites dans la base "TV" de skiFFS. Le script lua se charge de làcer un script python aggisant comme serveur TCP. Il repond aux commandes PING;/r/n et RANKING;/r/n afin de renvoyer les donnees de course sous forme de json.

