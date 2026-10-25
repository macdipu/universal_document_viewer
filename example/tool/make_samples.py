"""Builds the example app's sample documents in assets/samples.

    pip install reportlab openpyxl python-docx
    python3 tool/make_samples.py

The PowerPoint sample is built with the kit's `buildPptx` (see README.md);
this script only renames its title.
"""
import os
import struct
import zipfile
import zlib

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Inches
from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.formatting.rule import CellIsRule, ColorScaleRule, DataBarRule, Rule
from openpyxl.styles import Border, Font, PatternFill, Side
from openpyxl.styles.differential import DifferentialStyle
from reportlab.lib import pdfencrypt
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'assets', 'samples')


CHAPTERS = [
    ('Opening a document', 'One widget, DocumentViewer.file(path), picks the right reader from the file name. '
     'PDF, Word, Excel, CSV, PowerPoint and plain text all open the same way, and a typed error says why a file '
     'could not be read: too large, damaged, protected by a password or not a supported kind of file.'),
    ('Reading PDF', 'Pages are drawn by PDFium and built only near the viewport. Each page starts as a small image '
     'and is sharpened with tiles as you zoom in, so a long report stays smooth on a modest phone. Pinch, '
     'double-tap or use the mouse wheel to zoom.'),
    ('Reading Word', 'A .docx is parsed in a background isolate and reflowed to the screen, or laid out in print '
     'pages with their headers, footers and page numbers. Styles, lists, tables with merged cells, images, '
     'footnotes and links are all kept.'),
    ('Reading spreadsheets', 'Excel workbooks and CSV files open in a lazy grid that builds only the cells on screen. '
     'Column widths, frozen panes, merged cells, number formats, borders, conditional formatting and notes come '
     'from the file itself.'),
    ('Reading slides', 'PowerPoint decks show one slide at a time with their titles, text, tables and pictures, and a '
     'bar to move between slides.'),
    ('Searching', 'Every reader can search. Matches are highlighted and you can step through them one by one; '
     'a scanned PDF without a text layer is detected so the app can say why nothing was found.'),
    ('Resuming where you left off', 'Each reader reports its position as a small JSON-safe map. Store it however you '
     'like, pass it back as initialPosition, and the document reopens on the same page, slide, row or line.'),
    ('Thumbnails', 'DocumentThumbnails renders a PNG of any document, and of the page a saved position resumes on, '
     'so a library screen can show where each file was left.'),
    ('Safety', 'Office files are checked before they are parsed. Damaged archives, paths that try to leave the '
     'archive and oversized contents are refused instead of filling memory.'),
    ('Your own interface', 'When the ready-made viewer is not enough, use the controller and view for one format and '
     'build your own app bar, search field and page indicator around them.'),
    ('Platforms', 'Android, iOS, macOS, Windows and Linux. The engines are part of the package, so there is no '
     'other document plugin or web view to add.'),
]


def wrap(c, text, x, y, width, font='Helvetica', size=11, leading=16):
    """Draws [text] wrapped to [width]; returns the y below it."""
    from reportlab.pdfbase.pdfmetrics import stringWidth
    line = ''
    for word in text.split():
        candidate = f'{line} {word}'.strip()
        if stringWidth(candidate, font, size) > width:
            c.drawString(x, y, line)
            y -= leading
            line = word
        else:
            line = candidate
    if line:
        c.drawString(x, y, line)
        y -= leading
    return y


def guide_pdf(name='guide.pdf', password=None):
    """A cover and eleven chapters with a heading each, so page and resume are easy to see."""
    encrypt = pdfencrypt.StandardEncryption(password, canPrint=1) if password else None
    c = canvas.Canvas(os.path.join(OUT, name), pagesize=A4, encrypt=encrypt)
    c.setTitle('universal_document_viewer guide')
    width, height = A4
    for page in range(1, 13):
        if page == 1:
            c.setFillColorRGB(0.20, 0.25, 0.60)
            c.rect(0, height - 300, width, 300, stroke=0, fill=1)
            c.setFillColorRGB(1, 1, 1)
            c.setFont('Helvetica-Bold', 30)
            c.drawString(56, height - 170, 'Reading documents')
            c.drawString(56, height - 206, 'in Flutter')
            c.setFont('Helvetica', 14)
            c.drawString(56, height - 250, 'A short guide to universal_document_viewer')
            c.setFillColorRGB(0.1, 0.1, 0.1)
            c.setFont('Helvetica-Bold', 16)
            c.drawString(56, height - 350, 'Chapter 1: What it reads')
            c.setFont('Helvetica', 11)
            y = wrap(c, 'Six kinds of document, read by engines that ship inside the package. The chart below shows '
                        'how many of the sample files are in each format.', 56, height - 378, width - 112)
            formats = [('PDF', 2, (0.80, 0.20, 0.20)), ('Word', 1, (0.15, 0.35, 0.75)), ('Excel', 1, (0.10, 0.55, 0.30)),
                       ('CSV', 1, (0.05, 0.50, 0.50)), ('Slides', 1, (0.85, 0.45, 0.10)), ('Text', 1, (0.40, 0.40, 0.45))]
            base = y - 200
            for i, (label, count, rgb) in enumerate(formats):
                x = 70 + i * 78
                c.setFillColorRGB(*rgb)
                c.rect(x, base, 48, count * 80, stroke=0, fill=1)
                c.setFillColorRGB(0.2, 0.2, 0.2)
                c.setFont('Helvetica', 10)
                c.drawCentredString(x + 24, base - 16, label)
            c.setFillColorRGB(0.1, 0.3, 0.8)
            c.setFont('Helvetica', 11)
            c.drawString(56, 80, 'Flutter website (a web link)')
            c.linkURL('https://flutter.dev/', (56, 75, 230, 92), relative=0)
        else:
            title, body = CHAPTERS[page - 2]
            c.setFillColorRGB(0.20, 0.25, 0.60)
            c.rect(0, height - 8, width, 8, stroke=0, fill=1)
            c.setFillColorRGB(0.1, 0.1, 0.1)
            c.setFont('Helvetica-Bold', 22)
            c.drawString(56, 770, f'Chapter {page}')
            c.setFont('Helvetica', 15)
            c.setFillColorRGB(0.20, 0.25, 0.60)
            c.drawString(56, 746, title)
            c.setFillColorRGB(0.1, 0.1, 0.1)
            c.setFont('Helvetica', 11)
            y = wrap(c, body, 56, 712, width - 112) - 8
            # Fill the page with the other chapters' text, so each page scrolls like a real one.
            for line in range(1, len(CHAPTERS)):
                if y < 120:
                    break
                y = wrap(c, CHAPTERS[(page + line) % len(CHAPTERS)][1], 56, y, width - 112, leading=15) - 8
        c.setFillColorRGB(0.4, 0.4, 0.4)
        c.setFont('Helvetica', 9)
        c.drawString(500, 30, f'{page} / 12')
        c.showPage()
    c.save()


def sales_xlsx():
    """Borders, conditional formatting, notes, formulas and a long sheet."""
    wb = Workbook()
    ws = wb.active
    ws.title = 'Regions'
    thin, thick, double = Side(style='thin'), Side(style='thick'), Side(style='double')
    ws.append(['Region', 'Units', 'Target', 'Status', 'Score'])
    rows = [('North', 120, 100, 'On track', 35), ('South', 80, 100, 'Overdue', 90), ('East', 150, 120, 'On track', 60),
            ('West', 40, 90, 'Overdue', 10), ('Central', 95, 95, 'Review', 75)]
    # openpyxl saves formulas without results and the reader shows a formula
    # it has no result for, so the totals are stored as values.
    for row in rows:
        ws.append(list(row))
    for cell in ws[1]:
        cell.font = Font(bold=True)
        cell.fill = PatternFill('solid', fgColor='DDEBF7')
        cell.border = Border(bottom=thick, top=thin, left=thin, right=thin)
    for row in ws.iter_rows(min_row=2, max_row=6, max_col=5):
        for cell in row:
            cell.border = Border(left=thin, right=thin, top=thin, bottom=thin)
    ws['A8'] = 'Total'
    ws['A8'].font = Font(bold=True)
    ws['B8'] = sum(row[1] for row in rows)
    ws['C8'] = sum(row[2] for row in rows)
    for cell in ws[8][:5]:
        cell.border = Border(top=thin, bottom=double)
    red = DifferentialStyle(font=Font(color='9C0006', bold=True), fill=PatternFill(bgColor='FFC7CE'))
    ws.conditional_formatting.add('B2:B6', CellIsRule(operator='lessThan', formula=['C2'], font=Font(color='9C0006'),
                                                      fill=PatternFill(bgColor='FFC7CE')))
    overdue = Rule(type='containsText', operator='containsText', text='Overdue', dxf=red)
    overdue.formula = ['NOT(ISERROR(SEARCH("Overdue",D2)))']
    ws.conditional_formatting.add('D2:D6', overdue)
    ws.conditional_formatting.add('E2:E6', DataBarRule(start_type='num', start_value=0, end_type='num', end_value=100,
                                                       color='638EC6'))
    ws['B3'].comment = Comment('Shipment delayed - confirm with logistics', 'Rina')
    ws['A8'].comment = Comment('Excludes returns', 'Sam')
    for column, width in zip('ABCDE', (9, 7, 7, 10, 8)):
        ws.column_dimensions[column].width = width

    orders = wb.create_sheet('Orders')
    orders.append(['Order', 'Customer', 'Amount', 'Status'])
    for cell in orders[1]:
        cell.font = Font(bold=True)
    for i in range(1, 301):
        orders.append([f'ORD-{i:04d}', f'Customer {i % 37}', i * 13 % 997, 'Open' if i % 5 else 'Late'])
    orders.conditional_formatting.add('C2:C301', ColorScaleRule(start_type='min', start_color='F8696B',
                                                                mid_type='percentile', mid_value=50,
                                                                mid_color='FFEB84', end_type='max',
                                                                end_color='63BE7B'))
    orders.column_dimensions['B'].width = 14
    wb.save(os.path.join(OUT, 'sales.xlsx'))


def data_csv():
    with open(os.path.join(OUT, 'contacts.csv'), 'w', encoding='utf-8', newline='') as f:
        f.write('Name,City,Phone,Note\n')
        cities = ['Dhaka', 'Chattogram', 'Sylhet', 'Khulna', 'Rajshahi']
        for i in range(1, 121):
            f.write(f'Person {i},{cities[i % 5]},+880 1{i:09d},"Met at event {i % 7}, follow up"\n')


def notes_txt():
    """Plain-text reading notes, long enough to scroll and resume."""
    with open(os.path.join(OUT, 'notes.txt'), 'w', encoding='utf-8') as f:
        f.write('READING NOTES\n=============\n\n')
        for i in range(1, 121):
            title, body = CHAPTERS[i % len(CHAPTERS)]
            f.write(f'Note {i}: {title}\n{body}\n\n')


def bar_chart_png(values, width=480, height=200):
    """A plain bar chart as PNG bytes, for the Word sample's picture."""
    colors = [(0x15, 0x65, 0xC0), (0x2E, 0x7D, 0x32), (0xE6, 0x51, 0x00), (0xC6, 0x28, 0x28), (0x00, 0x79, 0x6B)]
    bar = width // (len(values) * 2)
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            index, offset = divmod(x - bar // 2, bar * 2)
            top = height - int(values[index] / max(values) * (height - 10)) if 0 <= index < len(values) else height
            row += bytes(colors[index % len(colors)]) if 0 <= offset < bar and y >= top else b'\xff\xff\xff'
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')


def shade(cell, fill):
    properties = cell._tc.get_or_add_tcPr()
    shading = OxmlElement('w:shd')
    shading.set(qn('w:val'), 'clear')
    shading.set(qn('w:fill'), fill)
    properties.append(shading)


def report_docx():
    """A short business report: headings, styled text, lists, a shaded table, a chart and a header."""
    doc = Document()
    doc.sections[0].header.paragraphs[0].text = 'Northwind Trading - Quarterly Report'
    doc.add_heading('Quarterly Report', level=0)
    intro = doc.add_paragraph('Third quarter, prepared for the board. ')
    intro.add_run('Revenue grew 18%').bold = True
    intro.add_run(' on the previous quarter, led by the East region; ')
    late = intro.add_run('two regions missed their targets')
    late.font.color.rgb = RGBColor(0xC6, 0x28, 0x28)
    intro.add_run('. The details below are ')
    intro.add_run('provisional').italic = True
    intro.add_run(' until the audit closes.')

    doc.add_heading('Highlights', level=1)
    for item in ('East shipped 150 units against a target of 120.', 'New customers: 37, up from 29.',
                 'Average delivery time fell to 3.2 days.'):
        doc.add_paragraph(item, style='List Bullet')

    doc.add_heading('Units by region', level=1)
    rows = [('Region', 'Units', 'Target', 'Status'), ('North', '120', '100', 'On track'), ('South', '80', '100', 'Behind'),
            ('East', '150', '120', 'On track'), ('West', '40', '90', 'Behind'), ('Central', '95', '95', 'On track')]
    table = doc.add_table(rows=len(rows), cols=4)
    table.style = 'Table Grid'
    for r, values in enumerate(rows):
        for c, value in enumerate(values):
            cell = table.cell(r, c)
            cell.text = value
            if r == 0:
                cell.paragraphs[0].runs[0].bold = True
                shade(cell, 'DDEBF7')
            elif value == 'Behind':
                shade(cell, 'FFC7CE')
    doc.add_paragraph()
    picture = os.path.join(OUT, '.chart.png')
    with open(picture, 'wb') as f:
        f.write(bar_chart_png([120, 80, 150, 40, 95]))
    doc.add_picture(picture, width=Inches(4))
    os.remove(picture)
    caption = doc.add_paragraph('Units shipped by region, July to September.')
    caption.alignment = WD_ALIGN_PARAGRAPH.CENTER
    caption.runs[0].font.size = Pt(9)

    doc.add_heading('Next quarter', level=1)
    for item in ('Restock the South warehouse before October.', 'Review West pricing with the sales team.',
                 'Report again in January.'):
        doc.add_paragraph(item, style='List Number')
    for chapter, body in CHAPTERS:
        doc.add_heading(chapter, level=2)
        doc.add_paragraph(body)
    doc.save(os.path.join(OUT, 'report.docx'))


def rename_deck(old='open_reader_kit', new='universal_document_viewer'):
    """The deck was built before the package was renamed; rewrites its title."""
    path = os.path.join(OUT, 'deck.pptx')
    with zipfile.ZipFile(path) as source:
        entries = [(info, source.read(info)) for info in source.infolist()]
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as target:
        for info, data in entries:
            if info.filename.startswith('ppt/slides/') and info.filename.endswith('.xml'):
                data = data.replace(old.encode(), new.encode())
            target.writestr(info, data)


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    guide_pdf()
    guide_pdf('locked.pdf', password='open')
    sales_xlsx()
    data_csv()
    notes_txt()
    rename_deck()
    report_docx()
    print('Samples written to', os.path.normpath(OUT))
