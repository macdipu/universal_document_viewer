"""Builds the PDF fixtures for the PDF engine tests with reportlab.

    python3 test/fixtures/pdf/generate.py
"""
import os

from reportlab.lib.pagesizes import A4, letter
from reportlab.lib import pdfencrypt
from reportlab.pdfgen import canvas

HERE = os.path.dirname(os.path.abspath(__file__))


def features():
    c = canvas.Canvas(os.path.join(HERE, 'features.pdf'), pagesize=letter)
    # Page 1: text, a web link annotation, an in-document link to page 3.
    c.setFont('Helvetica', 14)
    c.drawString(72, 700, 'Quarterly Report alpha')
    c.drawString(72, 680, 'The needle is on page one.')
    c.drawString(72, 640, 'Visit our site')
    c.linkURL('https://example.com/', (72, 635, 170, 655), relative=0)
    c.drawString(72, 600, 'Go to the end')
    c.bookmarkPage('p1')
    c.linkAbsolute('end', 'p3', (72, 595, 170, 615))
    c.showPage()
    # Page 2: A4, a phrase that wraps onto the next line.
    c.setPageSize(A4)
    c.setFont('Helvetica', 14)
    c.drawString(72, 760, 'This line ends with quarterly')
    c.drawString(72, 740, 'report and continues here.')
    c.showPage()
    # Page 3: turned 90 degrees by /Rotate. (reportlab swaps the media box
    # to landscape, 792 x 612, so the page shows as portrait.)
    c.setPageSize(letter)
    c.setPageRotation(90)
    c.bookmarkPage('p3')
    c.setFont('Helvetica', 14)
    c.drawString(72, 500, 'Rotated needle')
    c.showPage()
    # Page 4: no text at all (like a scan).
    c.setPageRotation(0)
    c.setPageSize(letter)
    c.rect(100, 100, 200, 200, fill=1)
    c.showPage()
    c.save()


def encrypted():
    enc = pdfencrypt.StandardEncryption('secret', canPrint=1)
    c = canvas.Canvas(os.path.join(HERE, 'encrypted.pdf'), pagesize=letter, encrypt=enc)
    c.setFont('Helvetica', 14)
    c.drawString(72, 700, 'Top secret text')
    c.showPage()
    c.save()


if __name__ == '__main__':
    features()
    encrypted()
    with open(os.path.join(HERE, 'broken.pdf'), 'wb') as f:
        f.write(b'%PDF-1.4\nthis is not really a pdf\n')
