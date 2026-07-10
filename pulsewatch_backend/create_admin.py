"""One-off CLI to bootstrap the first researcher/admin account.

There is no API route for creating researcher accounts — that's
intentional, so a researcher login can't be created remotely by anyone
who isn't already on the server. Run this manually on the VPS:

    .venv/bin/python create_admin.py
"""
import getpass

import auth


def main():
    auth.init_db()
    username = input('Researcher username: ').strip()
    if not username:
        print('Username cannot be empty.')
        return

    password = getpass.getpass('Password (min 8 chars): ')
    if len(password) < 8:
        print('Password must be at least 8 characters.')
        return

    confirm = getpass.getpass('Confirm password: ')
    if password != confirm:
        print('Passwords did not match.')
        return

    try:
        auth.create_researcher(username, password)
    except ValueError as e:
        print(f'Error: {e}')
        return

    print(f"Researcher account '{username}' created.")


if __name__ == '__main__':
    main()
