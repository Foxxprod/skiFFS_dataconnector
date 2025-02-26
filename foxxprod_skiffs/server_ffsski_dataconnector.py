import subprocess
import sys

# Liste des modules nécessaires
required_modules = [
    'mysql-connector-python',  # mysql.connector
    'pystray',  # pystray
    'Pillow',  # PIL (Pillow)
]

# Fonction pour installer les modules manquants
def install_required_modules():
    for module in required_modules:
        try:
            __import__(module)
        except ImportError:
            print(f"{module} n'est pas installé. Installation en cours...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", module])

# Appeler la fonction pour installer les modules nécessaires
install_required_modules()

import socket
import threading
import tkinter as tk
from tkinter import scrolledtext, messagebox
import mysql.connector
import json
import pystray
from pystray import MenuItem as item
from PIL import Image, ImageDraw
import time

# Configuration du serveur
HOST = '0.0.0.0'
PORT = 12345  # Port d'écoute
DB_CONFIG = {
    'host': '127.0.0.1',
    'user': 'root',
    'password': '',
    'database': 'tv'
}

# Variable globale pour suivre l'état de la connexion
connected = False
last_ping_time = 0

def handle_client(conn, addr, log_widget):
    global connected, last_ping_time
    log_widget.insert(tk.END, f"Connexion de {addr}\n")
    connected = True
    
    try:
        while True:
            data = conn.recv(1024).decode('utf-8').strip()
            if data == "PING;":
                last_ping_time = time.time()
                conn.sendall("PING;PONG\r\n".encode('utf-8'))
                
            elif data == "RANKING;":
                result = query_database()
                response = f"RANKING;{result}\r\n"
                conn.sendall(response.encode('utf-8'))
            else:
                log_widget.insert(tk.END, f"Message non reconnu: {data}\n")
    except Exception as e:
        log_widget.insert(tk.END, f"Erreur: {e}\n")
    finally:
        conn.close()
        log_widget.insert(tk.END, f"Déconnexion de {addr}\n")
        connected = False
        
def query_database():
    try:
        conn = mysql.connector.connect(**DB_CONFIG)
        cursor = conn.cursor()
        cursor.execute("""
            SELECT Startlist.Bib, Startlist.Identity, Startlist.Team, Startlist.Categ, Startlist.Sex, Ranking.Time 
            FROM Startlist 
            LEFT JOIN Ranking ON Startlist.Bib = Ranking.Bib;
        """)
        rows = cursor.fetchall()
        conn.close()
        result_json = json.dumps([{
            "ID": row[0],
            "Identity": row[1],
            "Team": row[2],
            "Categ": row[3],
            "Sex": row[4],
            "Time": row[5]
        } for row in rows])
        return result_json
    except mysql.connector.Error as err:
        return json.dumps({"error": str(err)})

def start_server(log_widget):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind((HOST, PORT))
    server.listen(5)
    log_widget.insert(tk.END, f"Serveur démarré sur {HOST}:{PORT}\n")
    while True:
        conn, addr = server.accept()
        client_thread = threading.Thread(target=handle_client, args=(conn, addr, log_widget))
        client_thread.start()

def run_server(log_widget):
    server_thread = threading.Thread(target=start_server, args=(log_widget,), daemon=True)
    server_thread.start()

def update_connection_status(log_widget):
    # Si le serveur est connecté, on vérifie si 10 secondes sont écoulées depuis le dernier PING
    if connected:
        if time.time() - last_ping_time <= 10:
            status_label.config(
                text="BIATHCG CONNECTÉE", fg="green")
        else:
            # Après 10 secondes sans PING, on passe à DÉCONNECTÉE
            status_label.config(
                text="BIATHCG DÉCONNECTÉE", fg="red")
            connected = False
    else:
        status_label.config(
            text="BIATHCG DÉCONNECTÉE", fg="red")

def reload_server(log_widget):
    global connected
    connected = False
    update_connection_status(log_widget)
    log_widget.insert(tk.END, "Redémarrage du serveur...\n")
    run_server(log_widget)

def on_close():
    if messagebox.askokcancel("Quitter", "Voulez-vous vraiment fermer le serveur?"):
        window.quit()

# Fonction pour créer l'icône et gérer le menu contextuel
def create_icon():
    icon_image = Image.new('RGBA', (64, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(icon_image)
    draw.rectangle([0, 0, 64, 64], fill="green")
    
    # Menu contextuel de l'icône
    def on_quit(icon, item):
        icon.stop()
        window.quit()

    menu = (item('Quitter', on_quit),)
    icon = pystray.Icon("Serveur", icon_image, menu=menu)
    icon.run()

# Interface graphique
def create_gui():
    global window, status_label
    window = tk.Tk()
    window.title("Serveur TCP")
    window.geometry("600x400")
    window.config(bg="#2e2e2e")  # Couleur de fond sombre

    # Label de statut de connexion
    status_label = tk.Label(window, text="BIATHCG DÉCONNECTÉE", fg="red", font=("Helvetica", 14), bg="#2e2e2e")
    status_label.pack(pady=10)

    # Zone de texte pour les logs
    log_widget = scrolledtext.ScrolledText(window, width=60, height=15, bg="#333333", fg="white", font=("Courier", 10))
    log_widget.pack(padx=20, pady=10)

    # Bouton pour démarrer le serveur
    start_button = tk.Button(window, text="Démarrer le serveur", command=lambda: run_server(log_widget), bg="#4CAF50", fg="white", font=("Helvetica", 12))
    start_button.pack(pady=5)

    # Bouton pour recharger le serveur
    reload_button = tk.Button(window, text="Recharger le serveur", command=lambda: reload_server(log_widget), bg="#FF9800", fg="white", font=("Helvetica", 12))
    reload_button.pack(pady=5)

    # Fermeture avec confirmation
    window.protocol("WM_DELETE_WINDOW", on_close)

    # Démarrage automatique du serveur
    run_server(log_widget)

    # Lancer l'icône de la barre de notification dans un thread séparé
    threading.Thread(target=create_icon, daemon=True).start()

    window.mainloop()

if __name__ == "__main__":
    create_gui()
